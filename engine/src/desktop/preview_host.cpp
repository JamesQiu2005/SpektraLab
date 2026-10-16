#include "preview_host.hpp"
#include "io/image_writer.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <limits>
#include <set>
#include <stdexcept>
#include <type_traits>
#include <utility>

namespace spk::desktop {
namespace {
namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;
using EnginePtr = std::unique_ptr<spk_engine, decltype(&spk_engine_destroy)>;
using SessionPtr = std::unique_ptr<spk_session, decltype(&spk_session_release)>;

double elapsed(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
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

// --- the settings table ---------------------------------------------------

using Member = std::variant<std::monostate, bool RenderSettings::*, double RenderSettings::*,
                            std::string RenderSettings::*>;
struct Row {
    SettingField field;
    Member member;  // monostate: stored by key
};

constexpr SettingLayer SHOOT = SettingLayer::shoot;
constexpr SettingLayer PRINT = SettingLayer::print;

Row number(std::string key, std::string label, SettingLayer layer, double low, double high,
           double initial, double absent, Member member = {}) {
    SettingField f{std::move(key), std::move(label), SettingType::number, layer, low, high};
    f.initial = initial;
    f.absent = absent;
    return {std::move(f), member};
}
Row number(std::string key, std::string label, SettingLayer layer, double low, double high,
           double initial, Member member) {
    return number(std::move(key), std::move(label), layer, low, high, initial, initial, member);
}
Row boolean(std::string key, std::string label, SettingLayer layer, bool initial, Member member = {}) {
    SettingField f{std::move(key), std::move(label), SettingType::boolean, layer};
    f.initial = initial;
    f.absent = initial;
    return {std::move(f), member};
}
Row text(std::string key, std::string label, SettingLayer layer, SettingChoices choices,
         std::vector<std::string> listed, std::string initial, std::string absent, Member member = {}) {
    SettingField f{std::move(key), std::move(label), SettingType::text, layer};
    f.choices = choices;
    f.listed = std::move(listed);
    f.initial = std::move(initial);
    f.absent = std::move(absent);
    return {std::move(f), member};
}

const std::vector<Row>& rows() {
    // A function-local table: RenderSettings' constructor reads it, so it
    // must exist before the first settings object, whatever the init order.
    static const std::vector<Row> table = [] {
        using R = RenderSettings;
        std::vector<Row> t;
        // A new photograph prints on Supra Endura, as on macOS
        // (Params.swift FilmParams.printStock). The engine's own default --
        // Portra Endura -- is what a record without the key rendered with.
        t.push_back(text("film_stock", "Film stock", SHOOT, SettingChoices::films, {},
                         "kodak_portra_400", "kodak_portra_400", &R::film_stock));
        t.push_back(text("print_stock", "Paper stock", PRINT, SettingChoices::papers, {},
                         "kodak_supra_endura", "kodak_portra_endura", &R::print_stock));
        t.push_back(number("print_exposure", "Print exposure", PRINT, 0.05, 20.0, 1.0, &R::print_exposure));
        t.push_back(number("exposure_compensation_ev", "Film exposure (EV)", SHOOT, -8.0, 8.0, 0.0,
                           &R::film_exposure_ev));
        // The engine's 35 mm, including its grain and halation scale; a UI
        // label such as "35 mm" is no licence to substitute 36.
        t.push_back(number("film_format_mm", "Film format (mm)", SHOOT, 4.0, 200.0, 35.0, &R::film_format_mm));
        t.push_back(boolean("grain_active", "Grain", SHOOT, true, &R::grain_active));
        t.push_back(number("grain_amount", "Grain amount", SHOOT, 0.0, 2.0, 1.0, &R::grain_amount));
        t.push_back(boolean("halation_active", "Halation", SHOOT, true, &R::halation_active));
        t.push_back(number("halation_amount", "Halation amount", SHOOT, 0.0, 4.0, 1.0, &R::halation_amount));
        t.push_back(boolean("glare_active", "Glare", PRINT, true, &R::glare_active));
        t.push_back(number("glare_amount", "Glare amount", PRINT, 0.0, 30.0, 1.0, &R::glare_amount));
        t.push_back(number("y_filter_shift", "Yellow filter shift", PRINT, -1.0, 1.0, 0.0, &R::y_filter_shift));
        t.push_back(number("m_filter_shift", "Magenta filter shift", PRINT, -1.0, 1.0, 0.0, &R::m_filter_shift));
        // What a unit of the two shifts is, in the enlarger head's CC (API-SPEC
        // §14). The engine's 1 makes the whole -1..1 slider one CC; macOS
        // sends 40 always (Params.swift FilmParams.filterShiftCC).
        t.push_back(number("filter_shift_scale", "Filter shift scale (CC)", PRINT, 1.0, 60.0, 40.0, 1.0));
        // RFC-015's metering intent. macOS starts new frames `balanced`
        // (Params.swift FilmParams.autoExposureMethod); a record without it
        // was metered with the engine's `center_weighted`.
        t.push_back(text("auto_exposure_method", "Metering", SHOOT, SettingChoices::listed,
                         {"balanced", "center", "protect_highlights", "protect_shadows",
                          "center_weighted", "average", "median"},
                         "balanced", "center_weighted"));
        return t;
    }();
    return table;
}

const Row& row_for(std::string_view key) {
    for (const Row& row : rows())
        if (row.field.key == key) return row;
    throw std::invalid_argument("Unknown render setting: " + std::string(key));
}

// The variant alternative a row's type stores.
std::size_t value_index(SettingType type) {
    switch (type) {
    case SettingType::boolean: return 0;
    case SettingType::number: return 1;
    case SettingType::text: return 2;
    }
    return std::variant_npos;
}

std::string number_text(double value) {
    char buffer[32];
    std::snprintf(buffer, sizeof buffer, "%g", value);
    return buffer;
}

Json to_json(const SettingValue& value) {
    return std::visit([](const auto& v) { return Json(v); }, value);
}

SessionPtr open_session(spk_engine* engine, const io::DecodedRaw& decoded,
                        const RenderSettings& settings, bool scan_film) {
    const spk_image input{decoded.rgb.data(), decoded.width, decoded.height, 3};
    const auto params = opening_params(settings, scan_film).dump();
    // No reply is needed here; the host has no allocator or JSON lifetime to
    // share with the UI, and the C API validates the complete delta itself.
    SessionPtr session(spk_open(engine, &input, params.c_str(), nullptr), &spk_session_release);
    require(bool(session), "Open image: " + std::string(spk_last_error(engine)));
    return session;
}
}  // namespace

const std::vector<SettingField>& setting_fields() {
    static const std::vector<SettingField> fields = [] {
        std::vector<SettingField> out;
        for (const Row& row : rows()) out.push_back(row.field);
        return out;
    }();
    return fields;
}

const SettingField* find_setting(std::string_view key) {
    for (const SettingField& field : setting_fields())
        if (field.key == key) return &field;
    return nullptr;
}

std::string check_setting(const SettingField& field, const SettingValue& value, const Catalog* catalog) {
    if (value.index() != value_index(field.type)) {
        const char* expected = field.type == SettingType::boolean ? "true or false"
                             : field.type == SettingType::number ? "a number" : "text";
        return field.label + " expects " + expected;
    }
    if (field.type == SettingType::number) {
        // Reject before touching the live session, including NaN/Inf values
        // that cannot be represented faithfully in the JSON parameter delta.
        const double v = std::get<double>(value);
        if (!std::isfinite(v) || v < field.low || v > field.high)
            return field.label + " must be between " + number_text(field.low) + " and " + number_text(field.high);
    } else if (field.type == SettingType::text) {
        const auto& v = std::get<std::string>(value);
        if (field.choices == SettingChoices::listed) {
            if (std::find(field.listed.begin(), field.listed.end(), v) == field.listed.end()) {
                std::string names;
                for (const auto& name : field.listed) names += (names.empty() ? "" : ", ") + name;
                return field.label + " must be one of: " + names;
            }
        } else if (catalog) {
            const bool film = field.choices == SettingChoices::films;
            const auto& stocks = film ? catalog->films : catalog->papers;
            if (std::none_of(stocks.begin(), stocks.end(), [&](const Stock& s) { return s.id == v; }))
                return std::string(film ? "Unknown film stock: " : "Unknown paper stock: ") + v;
        }
    }
    return {};
}

RenderSettings::RenderSettings() {
    for (const Row& row : rows()) {
        if (std::holds_alternative<std::monostate>(row.member)) by_key_.emplace(row.field.key, row.field.initial);
        else set(row.field.key, row.field.initial);
    }
}

SettingValue RenderSettings::get(std::string_view key) const {
    const Row& row = row_for(key);
    return std::visit([&](auto member) -> SettingValue {
        if constexpr (std::is_same_v<decltype(member), std::monostate>) return by_key_.find(key)->second;
        else return this->*member;
    }, row.member);
}

void RenderSettings::set(std::string_view key, SettingValue value) {
    const Row& row = row_for(key);
    if (value.index() != value_index(row.field.type))
        throw std::invalid_argument(check_setting(row.field, value));
    std::visit([&](auto member) {
        if constexpr (std::is_same_v<decltype(member), std::monostate>) by_key_.find(key)->second = std::move(value);
        else {
            using T = std::remove_reference_t<decltype(this->*member)>;
            this->*member = std::get<T>(std::move(value));
        }
    }, row.member);
}

bool validate_settings(const RenderSettings& settings, const Catalog& catalog) {
    for (const Row& row : rows()) {
        const auto error = check_setting(row.field, settings.get(row.field.key), &catalog);
        require(error.empty(), error);
    }
    const auto film = std::find_if(catalog.films.begin(), catalog.films.end(),
        [&](const Stock& stock) { return stock.id == settings.film_stock; });
    return film->is_positive;
}

Json opening_params(const RenderSettings& settings, bool scan_film) {
    Json params = Json::object();
    params.set("input_color_space", Json(std::string("ProPhoto RGB")));
    params.set("input_cctf_decoding", Json(false));
    params.set("output_color_space", Json(std::string("sRGB")));
    params.set("output_cctf_encoding", Json(true));
    params.set("extended_dynamic_range", Json(false));
    // Desktop policy matches the macOS session: a slide is already a
    // positive and must bypass negative-to-paper printing. The generic
    // engine API still permits deliberate positive-to-paper experiments.
    params.set("scan_film", Json(scan_film));
    // Every row, including the ones still at the engine's default: a
    // session is then fully described by the settings that opened it.
    for (const Row& row : rows()) params.set(row.field.key, to_json(settings.get(row.field.key)));
    return params;
}

Json changed_params(const RenderSettings& before, const RenderSettings& after, bool scan_film) {
    Json delta = Json::object();
    // The C API retains carried user controls when loading another stock.
    // Send only changed fields: an unchanged SHOOT field in a paper-only
    // delta would unnecessarily invalidate the cached grain realization, and
    // even an unchanged film_stock invalidates the negative.
    for (const Row& row : rows()) {
        const auto& key = row.field.key;
        auto value = after.get(key);
        if (before.get(key) == value) continue;
        delta.set(key, to_json(value));
        // Send false too when returning to negative film, otherwise the
        // previous slide's direct-scan mode would survive the stock change.
        if (key == "film_stock") delta.set("scan_film", Json(scan_film));
    }
    return delta;
}

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
    const bool scan_film = validate_settings(settings, impl_->catalog);
    require(mode == DecodeMode::compatible16 || mode == DecodeMode::headroom, "Unknown RAW decode mode");
    const auto path = fs::absolute(source);
    require(fs::is_regular_file(path), "RAW input is missing: " + utf8(path));
    auto next = std::shared_ptr<Frame>(new Frame());
    next->source = path;
    next->decode_mode = mode;
    next->settings = settings;
    next->scan_film = scan_film;
    io::DecodedRaw decoded;
    std::string error;
    auto t = Clock::now();
    const bool decoded_ok = mode == DecodeMode::headroom
        ? io::decode_raw_headroom(path, decoded, error)
        : io::decode_raw_compatible(path, decoded, error);
    require(decoded_ok, "RAW decode: " + error);
    next->timings.decode_ms = elapsed(t);
    next->metadata = decoded.metadata;
    next->decode_timings = decoded.timings;
    t = Clock::now();
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
    next->decode_mode = impl_->frame->decode_mode;
    next->settings = settings;
    next->scan_film = scan_film;
    next->metadata = impl_->frame->metadata;
    next->decode_timings = impl_->frame->decode_timings;
    const auto delta = changed_params(impl_->frame->settings, settings, scan_film);
    try {
        auto t = Clock::now();
        if (!impl_->session) {
            // C API settings changes may fail after applying part of their
            // state. Never reuse such a session; rebuild from the retained
            // decoded input on the next request, without decoding the file.
            impl_->session = open_session(impl_->engine.get(), impl_->decoded, settings, scan_film);
            next->timings.open_ms = elapsed(t);
        } else if (!delta.fields().empty()) {
            const auto text = delta.dump();
            const auto status = spk_set_params(impl_->session.get(), text.c_str(), nullptr);
            require(status == SPK_OK, "Apply settings: " + std::string(spk_last_error(impl_->engine.get())));
            next->timings.params_ms = elapsed(t);
        }
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
