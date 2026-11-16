#include "preview_host.hpp"
#include "io/image_writer.hpp"
#include "json.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <fstream>
#include <limits>
#include <set>
#include <stdexcept>
#include <type_traits>
#include <utility>

namespace spk::desktop {
std::map<std::string, SettingValue> default_advanced_settings() {
    return {
        {"camera_filter",""},
        {"density_curve_gamma",1.0},
        {"grain_sublayers_active",true},
        {"dir_couplers_active",true},
        {"dir_couplers_amount",1.0},
        {"halation_scatter_amount",1.0},
        {"halation_headroom_ev",4.0},
        {"halation_boost_ev",0.0},
        {"antihalation_removed",false},
        {"lens_blur_um",0.0},
        {"digital_intermediate",false},
        {"scene_curve",""},
        {"scene_latitude_active",false},
        {"scene_latitude_norm","power"},
        {"scene_latitude_highlight_knee",2.0},
        {"scene_latitude_highlight_room",0.0},
        {"scene_latitude_shadow_knee",-2.0},
        {"scene_latitude_shadow_room",0.0},
        {"scene_latitude_rolloff",2.0},
        {"scene_latitude_max_lift",4.0},
        {"contrast_mask_active",false},
        {"contrast_mask_highlights",0.0},
        {"contrast_mask_shadows",0.0},
        {"contrast_mask_core",1.0},
        {"contrast_mask_scale",0.03},
        {"scan_hdr_headroom",0.0},
        {"scan_hdr_stretch",false},
        {"scan_hdr_output_scale",1.0},
        {"enlarger_illuminant","TH-KG3"},
        {"y_filter_neutral",55.0},
        {"m_filter_neutral",65.0},
        {"c_filter_neutral",0.0},
        {"preflash_exposure",0.0},
        {"scanner_white_correction",false},
        {"scanner_black_correction",false},
        {"scanner_lens_blur",0.0},
        {"diffusion_filter_active",false},
        {"diffusion_filter_family","black_pro_mist"},
        {"diffusion_filter_strength",0.5},
        {"diffusion_filter_spatial_scale",1.0},
        {"diffusion_filter_halo_warmth",0.0},
        {"diffusion_filter_core_intensity",1.0},
        {"diffusion_filter_core_size",1.0},
        {"diffusion_filter_halo_intensity",1.0},
        {"diffusion_filter_halo_size",1.0},
        {"diffusion_filter_bloom_intensity",1.0},
        {"diffusion_filter_bloom_size",1.0},
        {"lens_aberrations_active",false},
        {"lens_field_curvature_um",0.0},
        {"lens_astigmatism_um",0.0},
        {"lens_field_exponent",2.0},
        {"lens_sharp_radius",0.0},
        {"lens_coma_um",0.0},
        {"lens_spherical_amount",0.0},
        {"lens_spherical_um",60.0},
        {"lens_lateral_ca_r",0.0},
        {"lens_lateral_ca_b",0.0},
        {"lens_loca_um",0.0},
        {"lens_loca_sign","purple"},
        {"lens_loca_highlight_gate",1.0},
        {"overscan_active",false},
        {"overscan_format","135"},
        {"overscan_mode","strip"},
        {"overscan_camera_seed",1},
        {"overscan_frame_seed",1},
        {"overscan_fog",1.0},
        {"overscan_leaks",0.0},
        {"overscan_edge_text",""},
        {"overscan_f_number",0.0},
        {"overscan_gate","auto"},
        {"overscan_holes","white"},
        {"overscan_frame_number",0},
        {"overscan_carrier","none"},
        {"overscan_pair",false},
        {"overscan_perforation","none"},
        {"overscan_falloff",0.0},
        {"date_imprint_active",false},
        {"date_imprint_text",""},
        {"date_imprint_text_b",""},
        {"date_imprint_data_text",""},
        {"date_imprint_placement","frame"},
        {"date_imprint_ev",5.5},
        {"date_imprint_style","lcd"},
        {"date_imprint_size",1.0},
        {"date_imprint_corner","br"},
        {"date_imprint_inset_x",3.0},
        {"date_imprint_inset_y",2.4},
        {"date_imprint_data_placement","gap"},
        {"date_imprint_data_leader",""},
        {"leak_kind","off"},
        {"leak_amount",1.0},
        {"leak_rate",1.0},
        {"leak_front",-1.0},
        {"scene_layer_active",false},
        {"scene_layer_x",0.5},
        {"scene_layer_y",0.5},
        {"scene_layer_radius_x",0.25},
        {"scene_layer_radius_y",0.25},
        {"scene_layer_feather",0.3},
        {"scene_layer_exposure_ev",1.0},
        {"scene_layer_coverage",1.0},
        {"scene_layer_shape","ellipse"},
        {"scene_layer_invert",false}
    };
}
namespace {
namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;
using EnginePtr = std::unique_ptr<spk_engine, decltype(&spk_engine_destroy)>;
using SessionPtr = std::unique_ptr<spk_session, decltype(&spk_session_release)>;

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

Json setting_json(const SettingValue& value) {
    return std::visit([](const auto& v) -> Json {
        if constexpr (std::is_same_v<std::decay_t<decltype(v)>, int>)
            return Json(double(v));
        else
            return Json(v);
    }, value);
}

void set_advanced(Json& params, const std::map<std::string, SettingValue>& values) {
    for (const auto& [name, value] : values)
        if (name.rfind("scene_layer_", 0) != 0) params.set(name, setting_json(value));
}

bool scene_layer_field_changed(const RenderSettings& before, const RenderSettings& after) {
    for (const auto& [name, value] : after.advanced)
        if (name.rfind("scene_layer_", 0) == 0) {
            const auto old = before.advanced.find(name);
            if (old == before.advanced.end() || old->second != value) return true;
        }
    return false;
}

bool boolean_advanced(const RenderSettings& settings, const char* key) {
    const auto found = settings.advanced.find(key);
    require(found != settings.advanced.end() && std::holds_alternative<bool>(found->second),
            std::string("Scene layer field is not boolean: ") + key);
    return std::get<bool>(found->second);
}

std::string string_advanced(const RenderSettings& settings, const char* key) {
    const auto found = settings.advanced.find(key);
    require(found != settings.advanced.end() && std::holds_alternative<std::string>(found->second),
            std::string("Scene layer field is not text: ") + key);
    return std::get<std::string>(found->second);
}

double number_advanced(const RenderSettings& settings, const char* key,
                       double low, double high) {
    const auto found = settings.advanced.find(key);
    require(found != settings.advanced.end() && std::holds_alternative<double>(found->second),
            std::string("Scene layer field is not numeric: ") + key);
    const double value = std::get<double>(found->second);
    require(std::isfinite(value) && value >= low && value <= high,
            std::string("Scene layer field is outside its range: ") + key);
    return value;
}

void apply_scene_layer(spk_engine* engine, spk_session* session, const RenderSettings& settings) {
    if (!boolean_advanced(settings, "scene_layer_active")) {
        require(spk_set_params(session, "{\"scene_layers\":\"\"}", nullptr) == SPK_OK,
                "Clear scene layer: " + std::string(spk_last_error(engine)));
        require(spk_set_scene_layers(session, nullptr, 0, nullptr, nullptr, nullptr) == SPK_OK,
                "Clear scene-layer planes: " + std::string(spk_last_error(engine)));
        return;
    }
    const double center_x = number_advanced(settings, "scene_layer_x", 0.0, 1.0);
    const double center_y = number_advanced(settings, "scene_layer_y", 0.0, 1.0);
    const double radius_x = number_advanced(settings, "scene_layer_radius_x", 0.01, 0.5);
    const double radius_y = number_advanced(settings, "scene_layer_radius_y", 0.01, 0.5);
    const double feather = number_advanced(settings, "scene_layer_feather", 0.0, 0.95);
    const double exposure = number_advanced(settings, "scene_layer_exposure_ev", -4.0, 4.0);
    const double coverage = number_advanced(settings, "scene_layer_coverage", 0.0, 1.0);
    const std::string shape = string_advanced(settings, "scene_layer_shape");
    require(shape == "ellipse" || shape == "rectangle",
            "Scene layer shape must be ellipse or rectangle");
    const bool invert = boolean_advanced(settings, "scene_layer_invert");
    constexpr uint32_t size = 256;
    std::vector<uint16_t> plane(std::size_t(size) * size);
    const double inner = 1.0 - feather;
    for (uint32_t y = 0; y < size; ++y) {
        for (uint32_t x = 0; x < size; ++x) {
            const double dx = std::abs((double(x) + 0.5) / size - center_x) / radius_x;
            const double dy = std::abs((double(y) + 0.5) / size - center_y) / radius_y;
            const double distance = shape == "ellipse" ? std::hypot(dx, dy) : std::max(dx, dy);
            double mask = distance <= inner ? 1.0 :
                          distance >= 1.0 ? 0.0 :
                          1.0 - (distance - inner) / std::max(1e-9, feather);
            mask = mask * mask * (3.0 - 2.0 * mask);
            if (invert) mask = 1.0 - mask;
            plane[std::size_t(y) * size + x] = uint16_t(std::lround(mask * 65535.0));
        }
    }
    const float gain = float(exposure * std::log(2.0));
    const spk_scene_layer layer{plane.data(), size, size, {gain, gain, gain}, float(coverage)};
    constexpr char stamp[] = "windows-desktop-layer-v1";
    require(spk_set_scene_layers(session, &layer, 1, nullptr, stamp, nullptr) == SPK_OK,
            "Set scene layer: " + std::string(spk_last_error(engine)));
    Json delta = Json::object();
    delta.set("scene_layers", Json(std::string(stamp)));
    require(spk_set_params(session, delta.dump().c_str(), nullptr) == SPK_OK,
            "Apply scene layer: " + std::string(spk_last_error(engine)));
}

double elapsed(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

std::string utf8(const fs::path& path) {
    const auto s = path.u8string();
    return {reinterpret_cast<const char*>(s.data()), s.size()};
}

Json read_json(const fs::path& path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    require(bool(file), "Cannot read bundled stock profile: " + utf8(path));
    const auto length = file.tellg();
    require(length > 0 && length <= 16 * 1024 * 1024, "Invalid bundled stock profile size");
    std::string text(std::size_t(length), '\0');
    file.seekg(0);
    require(bool(file.read(text.data(), std::streamsize(length))), "Cannot read complete stock profile");
    Json value;
    std::string error;
    const bool ok = Json::parse(text, value, error);
    require(ok, "Bundled stock profile: " + error);
    return value;
}

Catalog read_catalog(const fs::path& resources) {
    Catalog catalog;
    std::set<std::string> ids;
    for (const auto& entry : fs::directory_iterator(resources / "profiles")) {
        if (!entry.is_regular_file() || entry.path().extension() != ".json") continue;
        const Json profile = read_json(entry.path());
        const auto& info = profile.at("info");
        Stock stock{info.at("stock").as_string(), info.at("name").as_string()};
        const auto& stage = info.at("stage").as_string();
        const auto& type = info.at("type").as_string();
        require(!stock.id.empty() && stock.id == utf8(entry.path().stem()) &&
                    std::all_of(stock.id.begin(), stock.id.end(), [](unsigned char c) {
                        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                               (c >= '0' && c <= '9') || c == '_';
                    }), "Invalid stock identifier in bundled profile");
        require(!stock.label.empty() && ids.insert(stock.id).second,
                "Missing or duplicate bundled stock metadata");
        require(type == "negative" || type == "positive", "Unknown bundled stock type: " + type);
        stock.is_positive = type == "positive";
        if (stage == "filming") catalog.films.push_back(std::move(stock));
        else if (stage == "printing") catalog.papers.push_back(std::move(stock));
        else throw std::runtime_error("Unknown bundled stock stage: " + stage);
    }
    const auto by_label = [](const Stock& a, const Stock& b) { return a.label < b.label; };
    std::sort(catalog.films.begin(), catalog.films.end(), by_label);
    std::sort(catalog.papers.begin(), catalog.papers.end(), by_label);
    require(!catalog.films.empty() && !catalog.papers.empty(), "Bundled film/paper catalog is empty");
    return catalog;
}

bool validate_settings(const RenderSettings& settings, const Catalog& catalog) {
    const auto contains = [](const std::vector<Stock>& stocks, const std::string& id) {
        return std::any_of(stocks.begin(), stocks.end(), [&](const Stock& s) { return s.id == id; });
    };
    const auto film = std::find_if(catalog.films.begin(), catalog.films.end(),
        [&](const Stock& stock) { return stock.id == settings.film_stock; });
    require(film != catalog.films.end(), "Unknown film stock: " + settings.film_stock);
    require(contains(catalog.papers, settings.print_stock), "Unknown paper stock: " + settings.print_stock);
    require(std::isfinite(settings.print_exposure) && settings.print_exposure >= 0.05 &&
                settings.print_exposure <= 20.0, "Print exposure must be between 0.05 and 20");
    const auto range = [](double value, double low, double high, const char* label) {
        require(std::isfinite(value) && value >= low && value <= high,
                std::string(label) + " must be between " + std::to_string(low) + " and " + std::to_string(high));
    };
    // Reject before touching the live session, including NaN/Inf values
    // that cannot be represented faithfully in the JSON parameter delta.
    range(settings.film_exposure_ev, -8.0, 8.0, "Film exposure (EV)");
    range(settings.film_format_mm, 3.0, 300.0, "Film format (mm)");
    range(settings.grain_amount, 0.0, 2.0, "Grain amount");
    range(settings.halation_amount, 0.0, 4.0, "Halation amount");
    range(settings.glare_amount, 0.0, 30.0, "Glare amount");
    range(settings.y_filter_shift, -1.0, 1.0, "Yellow filter shift");
    range(settings.m_filter_shift, -1.0, 1.0, "Magenta filter shift");
    return film->is_positive;
}

Json opening_params(const RenderSettings& settings, bool scan_film) {
    // Unexposed effects keep their engine defaults. The exposed settings
    // start at those same defaults, so opening an unedited image retains
    // the existing look, including the physical 35 mm grain/halation scale.
    Json params = Json::object();
    params.set("input_color_space", Json(std::string("ProPhoto RGB")));
    params.set("input_cctf_decoding", Json(false));
    params.set("output_color_space", Json(std::string("sRGB")));
    params.set("output_cctf_encoding", Json(true));
    params.set("extended_dynamic_range", Json(false));
    params.set("film_stock", Json(settings.film_stock));
    // Desktop policy matches the macOS session: a slide is already a
    // positive and must bypass negative-to-paper printing. The generic
    // engine API still permits deliberate positive-to-paper experiments.
    params.set("scan_film", Json(scan_film));
    params.set("print_stock", Json(settings.print_stock));
    params.set("print_exposure", Json(settings.print_exposure));
    params.set("exposure_compensation_ev", Json(settings.film_exposure_ev));
    params.set("film_format_mm", Json(settings.film_format_mm));
    params.set("grain_active", Json(settings.grain_active));
    params.set("grain_amount", Json(settings.grain_amount));
    params.set("halation_active", Json(settings.halation_active));
    params.set("halation_amount", Json(settings.halation_amount));
    params.set("glare_active", Json(settings.glare_active));
    params.set("glare_amount", Json(settings.glare_amount));
    params.set("y_filter_shift", Json(settings.y_filter_shift));
    params.set("m_filter_shift", Json(settings.m_filter_shift));
    set_advanced(params, settings.advanced);
    return params;
}

Json changed_params(const RenderSettings& before, const RenderSettings& after, bool scan_film) {
    Json delta = Json::object();
    // Sending an unchanged film_stock still invalidates the negative in the
    // C API. A print-only edit must never include it incidentally.
    if (before.film_stock != after.film_stock) {
        delta.set("film_stock", Json(after.film_stock));
        // Send false too when returning to negative film, otherwise the
        // previous slide's direct-scan mode would survive the stock change.
        delta.set("scan_film", Json(scan_film));
    }
    if (before.print_stock != after.print_stock) delta.set("print_stock", Json(after.print_stock));
    if (before.print_exposure != after.print_exposure) delta.set("print_exposure", Json(after.print_exposure));
    // The C API retains carried user controls when loading another stock.
    // Send only changed fields: an unchanged SHOOT field in a paper-only
    // delta would unnecessarily invalidate the cached grain realization.
    if (before.film_exposure_ev != after.film_exposure_ev) delta.set("exposure_compensation_ev", Json(after.film_exposure_ev));
    if (before.film_format_mm != after.film_format_mm) delta.set("film_format_mm", Json(after.film_format_mm));
    if (before.grain_active != after.grain_active) delta.set("grain_active", Json(after.grain_active));
    if (before.grain_amount != after.grain_amount) delta.set("grain_amount", Json(after.grain_amount));
    if (before.halation_active != after.halation_active) delta.set("halation_active", Json(after.halation_active));
    if (before.halation_amount != after.halation_amount) delta.set("halation_amount", Json(after.halation_amount));
    if (before.glare_active != after.glare_active) delta.set("glare_active", Json(after.glare_active));
    if (before.glare_amount != after.glare_amount) delta.set("glare_amount", Json(after.glare_amount));
    if (before.y_filter_shift != after.y_filter_shift) delta.set("y_filter_shift", Json(after.y_filter_shift));
    if (before.m_filter_shift != after.m_filter_shift) delta.set("m_filter_shift", Json(after.m_filter_shift));
    for (const auto& [name, value] : after.advanced) {
        if (name.rfind("scene_layer_", 0) == 0) continue;
        const auto old = before.advanced.find(name);
        if (old == before.advanced.end() || old->second != value) delta.set(name, setting_json(value));
    }
    return delta;
}

SessionPtr open_session(spk_engine* engine, const io::DecodedRaw& decoded,
                        const RenderSettings& settings, bool scan_film) {
    const spk_image input{decoded.rgb.data(), decoded.width, decoded.height, 3};
    const auto params = opening_params(settings, scan_film).dump();
    // No reply is needed here; the host has no allocator or JSON lifetime to
    // share with the UI, and the C API validates the complete delta itself.
    SessionPtr session(spk_open(engine, &input, params.c_str(), nullptr), &spk_session_release);
    require(bool(session), "Open image: " + std::string(spk_last_error(engine)));
    apply_scene_layer(engine, session.get(), settings);
    return session;
}
}  // namespace

Frame::~Frame() { spk_result_free(&result_); }

std::vector<std::uint8_t> rgba16_to_bgra8(const spk_result& result) {
    require(result.rgba16 && result.width && result.height && result.row_stride_px >= result.width,
            "Invalid RGBA16 display dimensions or row pitch");
    constexpr auto max_size = std::numeric_limits<std::size_t>::max();
    // Both the source address calculation and destination allocation must fit;
    // checking pixels alone would miss overflow of the row padding.
    require(std::size_t(result.height) <= max_size / result.row_stride_px / 4 / sizeof(std::uint16_t) &&
                std::size_t(result.height) <= max_size / result.width / 4,
            "RGBA16 display dimensions overflow address space");
    const std::size_t count = std::size_t(result.width) * result.height * 4;
    require(count <= std::vector<std::uint8_t>().max_size(), "BGRA8 display allocation is too large");
    std::vector<std::uint8_t> bgra(count);
    const auto byte = [](std::uint16_t value) {
        return std::uint8_t((std::uint32_t(value) + 128u) / 257u);
    };
    for (std::size_t y = 0; y < result.height; ++y) {
        const auto* src = result.rgba16 + y * result.row_stride_px * 4;
        auto* dst = bgra.data() + y * result.width * 4;
        for (std::size_t x = 0; x < result.width; ++x) {
            if (src[4 * x + 3] != 65535)
                throw std::runtime_error("Display requires opaque RGBA16 pixels");
            dst[4 * x] = byte(src[4 * x + 2]);
            dst[4 * x + 1] = byte(src[4 * x + 1]);
            dst[4 * x + 2] = byte(src[4 * x]);
            dst[4 * x + 3] = 255;
        }
    }
    return bgra;
}

io::DecodedRaw compose_half_frame_pair(const io::DecodedRaw& left, const io::DecodedRaw& right) {
    require(left.width && left.height && right.width && right.height, "Half-frame source has no pixels");
    require(left.rgb.size() == std::size_t(left.width) * left.height * 3 &&
            right.rgb.size() == std::size_t(right.width) * right.height * 3,
            "Half-frame source has an invalid pixel buffer");
    const std::uint32_t height = std::max(left.height, right.height);
    const std::uint32_t cell_width = std::max(1u, std::uint32_t(std::lround(height * 18.0 / 24.0)));
    const std::uint32_t gap = std::max(1u, height / 24);
    const std::uint32_t width = cell_width * 2 + gap;
    io::DecodedRaw result = left;
    result.width = width;
    result.height = height;
    result.rgb.assign(std::size_t(width) * height * 3, 0.0f);
    result.timings.open_ms += right.timings.open_ms;
    result.timings.unpack_ms += right.timings.unpack_ms;
    result.timings.process_ms += right.timings.process_ms;
    result.timings.convert_ms += right.timings.convert_ms;
    result.timings.total_ms += right.timings.total_ms;
    const auto draw = [&](const io::DecodedRaw& source, std::uint32_t offset) {
        const double fit_height = std::max(double(source.height),
            double(source.width) * 24.0 / 18.0);
        const double fit_width = fit_height * 18.0 / 24.0;
        const double source_top = (fit_height - source.height) * 0.5;
        const double source_left = (fit_width - source.width) * 0.5;
        for (std::uint32_t y = 0; y < height; ++y) {
            const double sy = std::clamp((y + 0.5) * fit_height / height - source_top,
                0.0, double(source.height - 1));
            const std::uint32_t y0 = std::uint32_t(sy);
            const std::uint32_t y1 = std::min<std::uint32_t>(y0 + 1, source.height - 1);
            const double fy = sy - y0;
            for (std::uint32_t x = 0; x < cell_width; ++x) {
                const double sx = std::clamp((x + 0.5) * fit_width / cell_width - source_left,
                    0.0, double(source.width - 1));
                const std::uint32_t x0 = std::uint32_t(sx);
                const std::uint32_t x1 = std::min<std::uint32_t>(x0 + 1, source.width - 1);
                const double fx = sx - x0;
                for (std::uint32_t channel = 0; channel < 3; ++channel) {
                    const auto s = [&](std::uint32_t sx, std::uint32_t sy) {
                        return source.rgb[(std::size_t(sy) * source.width + sx) * 3 + channel];
                    };
                    const double top = s(x0, y0) * (1 - fx) + s(x1, y0) * fx;
                    const double bottom = s(x0, y1) * (1 - fx) + s(x1, y1) * fx;
                    result.rgb[(std::size_t(y) * width + offset + x) * 3 + channel] =
                        float(top * (1 - fy) + bottom * fy);
                }
            }
        }
    };
    draw(left, 0);
    draw(right, cell_width + gap);
    return result;
}

struct PreviewHost::Impl {
    fs::path resources;
    Catalog catalog;
    double engine_create_ms = 0.0;
    EnginePtr engine{nullptr, &spk_engine_destroy};
    // Declaration order makes session release precede engine destruction.
    SessionPtr session{nullptr, &spk_session_release};
    // Retained only for reopening after a failed settings/render operation.
    // Ordinary parameter edits reuse the current GPU source and negative.
    io::DecodedRaw decoded;
    FramePtr frame;
};

bool digital_intermediate_enabled(const RenderSettings& settings) {
    const auto it = settings.advanced.find("digital_intermediate");
    return it != settings.advanced.end() && std::holds_alternative<bool>(it->second) &&
           std::get<bool>(it->second);
}

PreviewHost::PreviewHost(const fs::path& resources) : impl_(std::make_unique<Impl>()) {
    impl_->resources = fs::absolute(resources);
    const auto path = utf8(impl_->resources);
    require(std::all_of(path.begin(), path.end(), [](unsigned char c) { return c < 128; }),
            "Engine resources directory currently requires an ASCII path");
    require(fs::is_directory(impl_->resources), "Engine resources directory is missing");
    impl_->catalog = read_catalog(impl_->resources);
    const auto started = Clock::now();
    impl_->engine.reset(spk_engine_create(path.c_str(), nullptr));
    impl_->engine_create_ms = elapsed(started);
    require(bool(impl_->engine), "Engine creation failed: " + std::string(spk_last_error(nullptr)));
}

PreviewHost::~PreviewHost() = default;
const Catalog& PreviewHost::catalog() const noexcept { return impl_->catalog; }
double PreviewHost::engine_create_ms() const noexcept { return impl_->engine_create_ms; }
FramePtr PreviewHost::current() const noexcept { return impl_->frame; }

FramePtr PreviewHost::open_raw(const fs::path& source, DecodeMode mode, const RenderSettings& settings) {
    const auto started = Clock::now();
    require(mode == DecodeMode::compatible16 || mode == DecodeMode::headroom, "Unknown RAW decode mode");
    const auto path = fs::absolute(source);
    require(fs::is_regular_file(path), "RAW input is missing: " + utf8(path));
    io::DecodedRaw decoded;
    std::string error;
    auto t = Clock::now();
    const bool decoded_ok = mode == DecodeMode::headroom
        ? io::decode_raw_headroom(path, decoded, error)
        : io::decode_raw_compatible(path, decoded, error);
    require(decoded_ok, "RAW decode: " + error);
    const auto decode_ms = elapsed(t);
    return open_decoded(path, std::move(decoded), {path}, mode, settings, decode_ms, started);
}

FramePtr PreviewHost::open_raw_pair(const fs::path& left, const fs::path& right,
                                    DecodeMode mode, const RenderSettings& settings) {
    const auto started = Clock::now();
    require(mode == DecodeMode::compatible16 || mode == DecodeMode::headroom, "Unknown RAW decode mode");
    const auto left_path = fs::absolute(left), right_path = fs::absolute(right);
    require(fs::is_regular_file(left_path), "RAW input is missing: " + utf8(left_path));
    require(fs::is_regular_file(right_path), "RAW input is missing: " + utf8(right_path));
    const auto decode = [&](const fs::path& path, io::DecodedRaw& decoded) {
        std::string error;
        const bool ok = mode == DecodeMode::headroom
            ? io::decode_raw_headroom(path, decoded, error)
            : io::decode_raw_compatible(path, decoded, error);
        require(ok, "RAW decode: " + error);
    };
    auto t = Clock::now();
    io::DecodedRaw left_decoded, right_decoded;
    decode(left_path, left_decoded);
    decode(right_path, right_decoded);
    const auto decode_ms = elapsed(t);
    auto composed = compose_half_frame_pair(left_decoded, right_decoded);
    return open_decoded(left_path, std::move(composed),
        {left_path, right_path}, mode, settings, decode_ms, started);
}

FramePtr PreviewHost::open_decoded(const fs::path& source, io::DecodedRaw decoded,
                                   std::vector<fs::path> pair_sources, DecodeMode mode,
                                   const RenderSettings& settings,
                                   double decode_ms,
                                   std::chrono::steady_clock::time_point started) {
    const bool scan_film = validate_settings(settings, impl_->catalog);
    auto next = std::shared_ptr<Frame>(new Frame());
    next->source = source;
    next->pair_sources = std::move(pair_sources);
    next->decode_mode = mode;
    next->settings = settings;
    next->scan_film = scan_film;
    next->digital_intermediate = digital_intermediate_enabled(settings);
    if (next->digital_intermediate)
        next->di_view_table = impl_->resources / "DIView-Cineon-to-ProPhoto.cube";
    next->metadata = decoded.metadata;
    next->decode_timings = decoded.timings;
    next->timings.decode_ms = decode_ms;
    auto t = Clock::now();
    auto session = open_session(impl_->engine.get(), decoded, settings, scan_film);
    next->timings.open_ms = elapsed(t);
    t = Clock::now();
    const auto status = spk_render(session.get(), "full", &next->result_);
    require(status == SPK_OK, "Render: " + std::string(spk_last_error(impl_->engine.get())));
    next->timings.render_ms = elapsed(t);
    next->timings.engine_render_ms = next->result_.elapsed_ms;
    t = Clock::now();
    next->bgra8 = rgba16_to_bgra8(next->result_);
    next->timings.display_ms = elapsed(t);
    // Commit only after all allocations and GPU/CPU work succeeded.
    impl_->session = std::move(session);
    impl_->decoded = std::move(decoded);
    impl_->frame = next;
    next->timings.total_ms = elapsed(started);
    return next;
}

FramePtr PreviewHost::render(const RenderSettings& settings) {
    const auto started = Clock::now();
    require(bool(impl_->frame), "Open a RAW image before rendering");
    const bool scan_film = validate_settings(settings, impl_->catalog);
    auto next = std::shared_ptr<Frame>(new Frame());
    next->source = impl_->frame->source;
    next->pair_sources = impl_->frame->pair_sources;
    next->decode_mode = impl_->frame->decode_mode;
    next->settings = settings;
    next->scan_film = scan_film;
    next->digital_intermediate = digital_intermediate_enabled(settings);
    if (next->digital_intermediate)
        next->di_view_table = impl_->resources / "DIView-Cineon-to-ProPhoto.cube";
    next->metadata = impl_->frame->metadata;
    next->decode_timings = impl_->frame->decode_timings;
    const auto delta = changed_params(impl_->frame->settings, settings, scan_film);
    try {
        auto t = Clock::now();
        bool opened = false;
        if (!impl_->session) {
            // C API settings changes may fail after applying part of their
            // state. Never reuse such a session; rebuild from the retained
            // decoded input on the next request, without decoding the file.
            impl_->session = open_session(impl_->engine.get(), impl_->decoded, settings, scan_film);
            opened = true;
            next->timings.open_ms = elapsed(t);
        } else if (!delta.fields().empty()) {
            const auto text = delta.dump();
            const auto status = spk_set_params(impl_->session.get(), text.c_str(), nullptr);
            require(status == SPK_OK, "Apply settings: " + std::string(spk_last_error(impl_->engine.get())));
            next->timings.params_ms = elapsed(t);
        }
        if (!opened && scene_layer_field_changed(impl_->frame->settings, settings))
            apply_scene_layer(impl_->engine.get(), impl_->session.get(), settings);
        t = Clock::now();
        const auto status = spk_reprint(impl_->session.get(), "full", &next->result_);
        require(status == SPK_OK, "Render: " + std::string(spk_last_error(impl_->engine.get())));
        next->timings.render_ms = elapsed(t);
        next->timings.engine_render_ms = next->result_.elapsed_ms;
        t = Clock::now();
        next->bgra8 = rgba16_to_bgra8(next->result_);
        next->timings.display_ms = elapsed(t);
    } catch (...) {
        impl_->session.reset();
        throw;
    }
    impl_->frame = next;
    next->timings.total_ms = elapsed(started);
    return next;
}

void PreviewHost::export_tiff(const Frame& frame, const fs::path& destination) const {
    const auto& pixels = frame.pixels();
    std::string error;
    const bool written = io::write_srgb_tiff(destination, pixels.rgba16, pixels.width, pixels.height,
                                            pixels.row_stride_px, impl_->resources / "io" / "sRGB.icc", error);
    require(written, "TIFF export: " + error);
}

}  // namespace spk::desktop
