#include "preview_host.hpp"
#include "io/image_writer.hpp"
#include "raw_white_balance.hpp"

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

// An optional text field of a profile's `info`; empty when absent or null
// (a slide's and every paper's `target_print` is null).
std::string info_text(const Json& info, const char* key) {
    const Json& value = info.at(key);
    return value.is_string() ? value.as_string() : std::string();
}

const Stock* find_stock(const std::vector<Stock>& stocks, std::string_view id) {
    const auto it = std::find_if(stocks.begin(), stocks.end(), [&](const Stock& s) { return s.id == id; });
    return it == stocks.end() ? nullptr : &*it;
}

std::vector<const Stock*> by_identifier(const std::vector<Stock>& stocks) {
    std::vector<const Stock*> out;
    for (const Stock& s : stocks) out.push_back(&s);
    std::sort(out.begin(), out.end(), [](const Stock* a, const Stock* b) { return a->id < b->id; });
    // macOS StockCatalog.filmsForPicker: stills, then cine, each in order.
    std::stable_partition(out.begin(), out.end(), [](const Stock* s) { return !s->is_cine; });
    return out;
}
}  // namespace

const Stock* Catalog::film(std::string_view id) const { return find_stock(films, id); }
const Stock* Catalog::paper(std::string_view id) const { return find_stock(papers, id); }

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
        // Optional, as gen-catalog.py treats them: absent is a still colour
        // stock that names no paper.
        stock.is_cine = info_text(info, "use") == "cine";
        stock.is_monochrome = info_text(info, "channel_model") == "bw";
        stock.target_print = info_text(info, "target_print");
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

bool can_print(const Catalog& catalog, std::string_view film, std::string_view paper) {
    const Stock* f = catalog.film(film);
    const Stock* p = catalog.paper(paper);
    return !f || !p || f->is_monochrome == p->is_monochrome;
}

std::string paper_for_film(const Catalog& catalog, std::string_view film, const std::string& paper,
                           const std::string& fallback) {
    const Stock* f = catalog.film(film);
    // Only a paper the catalogue has: macOS checks `catalog.stock(target)`.
    const std::string target = f && catalog.paper(f->target_print) ? f->target_print : std::string();
    // macOS skips the move only when the paper already is the target, which
    // makes it unconditional; the code, not its comment, is the behaviour.
    std::string chosen = target.empty() ? paper : target;
    // Between colour and black and white the paper cannot stay.
    if (!can_print(catalog, film, chosen)) chosen = target.empty() ? fallback : target;
    return chosen;
}

std::vector<StockGroup> film_groups(const Catalog& catalog) {
    std::vector<StockGroup> groups{{"positive", {}}, {"negative", {}}};
    StockGroup silver{"blackAndWhite", {}};
    for (const Stock* s : by_identifier(catalog.films)) {
        if (s->is_positive) groups[0].stocks.push_back(s);
        else if (s->is_monochrome) silver.stocks.push_back(s);
        else groups[1].stocks.push_back(s);
    }
    // A third group, and only when the catalogue has any: a black-and-white
    // negative prints on a different paper (StockCatalog.swift:109-113).
    if (!silver.stocks.empty()) groups.push_back(std::move(silver));
    return groups;
}

std::vector<StockGroup> paper_groups(const Catalog& catalog) {
    std::vector<StockGroup> groups{{"still", {}}, {"cine", {}}};
    for (const Stock* s : by_identifier(catalog.papers)) groups[s->is_cine ? 1 : 0].stocks.push_back(s);
    return groups;
}

double own_grain(std::string_view film) {
    // Measured on engine renders at 6 um pixels, grain as one layer, net
    // density 1.0, 48 um aperture, against each maker's published diffuse RMS
    // granularity (Tri-X 17, T-Max 8, Acros II 7, HP5 Plus 16); the owner's
    // decision of 2026-10-07 that a film's grain is a per-film amount and not
    // an engine change. Nothing is measured into a colour film's: 1.
    if (film == "kodak_tri_x_400") return 1.70;
    if (film == "ilford_hp5_plus_400") return 1.49;
    if (film == "kodak_tmax_100") return 0.74;
    if (film == "fujifilm_neopan_acros_100_ii") return 0.64;
    return 1.0;
}

namespace {

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
// A product row: stored and saved, never sent (SettingField::wire). A record
// from before it existed was made with the behaviour `initial` names.
Row product(std::string key, std::string label, SettingLayer layer, bool initial) {
    Row row = boolean(std::move(key), std::move(label), layer, initial);
    row.field.wire = false;
    return row;
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
        // The rest of the macOS Film and Print sections' controls, each at the
        // engine's own default, which is also macOS's: `absent` is `initial`,
        // and no saved edit renders differently for the row being added.
        //
        // The meter switched off -- the AE Method pill's "Custom" (Params.swift
        // AEMethod, :176-240): Film Exposure is then measured from the
        // linearised frame and the metering intent above is kept for later.
        t.push_back(boolean("auto_exposure", "Auto exposure", SHOOT, true));
        // "No Print Profile" (PrintProfileSection.swift:110-127): scan the
        // developed film instead of printing it, the paper kept for when it
        // comes back. A slide is scanned whatever this says (wire_params).
        t.push_back(boolean("scan_film", "No print profile", PRINT, false));
        // Print Effects (PrintProfileSection.swift:152-164, Params.swift:641):
        // off leaves the paper's colour transformation and nothing else -- no
        // glare, no pre-flash -- and forgets neither (wire_params).
        t.push_back(product("print_effects", "Print effects", PRINT, true));
        // The enlarger's pre-flash (EnlargerSection.swift:53-57): uniform paper
        // exposure through the film's clear base. macOS shows it x100 and stops
        // at 0.03 of the wire's 0..1, the useful range measured there
        // (Params.swift:603-608).
        t.push_back(number("preflash_exposure", "Pre-flash", PRINT, 0.0, 0.03, 0.0, 0.0));
        // RFC-025's strengths the Film Format section shows when effects are
        // decoupled (ParameterSections.swift:105-139; Params.swift
        // EffectStrengths, whose ranges these are).
        t.push_back(boolean("antihalation_removed", "Anti-halation layer removed", SHOOT, false));
        t.push_back(number("halation_scatter_amount", "Halation scatter", SHOOT, 0.0, 1.0, 1.0, 1.0));
        t.push_back(number("halation_boost_ev", "Highlight boost (EV)", SHOOT, 0.0, 8.0, 0.0, 0.0));
        t.push_back(boolean("dir_couplers_active", "Couplers", SHOOT, true));
        // 1.5, not the wire's 4: above ~1.736 the coupler inverse's exposure
        // axis stops being monotonic (AGENTS.md trap 22).
        t.push_back(number("dir_couplers_amount", "Couplers amount", SHOOT, 0.0, 1.5, 1.0, 1.0));
        // The three-sub-layer grain model against one layer (the Film Format
        // menu's check, ParameterSections.swift:193). Never on a black-and-white
        // film, whatever this says (wire_params).
        t.push_back(boolean("grain_sublayers_active", "Sub-layer grain", SHOOT, true));

        // The Pre-Dev rail's rows. A product row here is no engine field:
        // stored, validated, saved, undone and synced like any row, never sent.
        const auto unsent = [](Row row) {
            row.field.wire = false;
            return row;
        };
        // The Camera section's white balance (WhiteBalanceRows.swift; the
        // values are Sidecar.swift DecodeSettings', :8-26). A decode setting
        // on macOS (ImageDecoder.swift:233-238) and here: open_raw reads these
        // three into the RAW decoder (raw_white_balance.hpp), so a change
        // re-decodes and develops a new negative. As Shot follows the camera
        // and ignores the numbers; a preset is its Kelvin at tint 0.
        // 2000..50000 K is the host protocol's range (engine/host/main.cpp);
        // macOS's sliders show 2000..12000 K and -150..150.
        t.push_back(unsent(text("white_balance", "White balance", SHOOT, SettingChoices::listed,
                                {"as_shot", "daylight", "cloudy", "shade", "tungsten", "fluorescent", "custom"},
                                "as_shot", "as_shot")));
        t.push_back(unsent(number("white_balance_temperature", "Temperature (K)", SHOOT,
                                  2000.0, 50000.0, 5500.0, 5500.0)));
        t.push_back(unsent(number("white_balance_tint", "Tint", SHOOT, -150.0, 150.0, 0.0, 0.0)));
        // RFC-023's Scene Latitude (API-SPEC §12), the Scene Placement section
        // (ParameterSections.swift:212-258): the resolved curve the Fit solved,
        // never the pull-backs (RFC-023 §8.3), at the engine's defaults, which
        // are macOS's (Params.swift SceneLatitudeSettings, :294-312). Shoot
        // layer: an edit re-develops. Set by the controller's placeScene through
        // the Fit (core/latitude_fit.hpp); spk_set_params refuses a curve whose
        // knees cross with both sides on.
        t.push_back(boolean("scene_latitude_active", "Scene placement", SHOOT, false));
        t.push_back(text("scene_latitude_norm", "Scene placement norm", SHOOT, SettingChoices::listed,
                         {"power", "y", "max"}, "power", "power"));
        t.push_back(number("scene_latitude_highlight_knee", "Highlight knee (EV)", SHOOT, -24.0, 24.0, 2.0, 2.0));
        t.push_back(number("scene_latitude_highlight_room", "Highlight room (EV)", SHOOT, 0.0, 24.0, 0.0, 0.0));
        t.push_back(number("scene_latitude_shadow_knee", "Shadow knee (EV)", SHOOT, -24.0, 24.0, -2.0, -2.0));
        t.push_back(number("scene_latitude_shadow_room", "Shadow room (EV)", SHOOT, 0.0, 24.0, 0.0, 0.0));
        t.push_back(number("scene_latitude_rolloff", "Placement roll-off", SHOOT, 1.0, 4.0, 2.0, 2.0));
        t.push_back(number("scene_latitude_max_lift", "Largest shadow lift (EV)", SHOOT, 0.25, 12.0, 4.0, 4.0));
        // ...and the UI state the curve was solved from, kept with the
        // photograph and never sent (§8.3): the two sliders' pull-backs in
        // stops, 0 being the side off, on macOS's 0..8 track (Latitude.swift
        // placementRange); and RFC-027 §4.1's pending fit -- a synced
        // placement carries its pull-backs and waits for its own frame's Fit
        // (Sidecar.swift placementNeedsFit, SettingsClipboard.swift:171-185).
        t.push_back(unsent(number("scene_latitude_highlight_pull_back", "Highlight pull-back (EV)", SHOOT,
                                  0.0, 8.0, 0.0, 0.0)));
        t.push_back(unsent(number("scene_latitude_shadow_pull_back", "Shadow pull-back (EV)", SHOOT,
                                  0.0, 8.0, 0.0, 0.0)));
        t.push_back(unsent(boolean("scene_latitude_needs_fit", "Placement awaiting its fit", SHOOT, false)));
        // RFC-024's Tone Mask (API-SPEC §11), the Tone Mask section
        // (ParameterSections.swift:272-323; Params.swift ContrastMaskSettings,
        // :253-281), at the engine's defaults, which are macOS's. Print layer:
        // an edit reprints the cached negative. Off with Print Effects
        // (wire_params).
        t.push_back(boolean("contrast_mask_active", "Tone mask", PRINT, false));
        t.push_back(number("contrast_mask_highlights", "Tone mask highlights (EV)", PRINT, 0.0, 3.0, 0.0, 0.0));
        t.push_back(number("contrast_mask_shadows", "Tone mask shadows (EV)", PRINT, 0.0, 3.0, 0.0, 0.0));
        t.push_back(number("contrast_mask_core", "Tone mask core (EV)", PRINT, 0.0, 3.0, 1.0, 1.0));
        t.push_back(number("contrast_mask_scale", "Tone mask radius", PRINT, 0.002, 0.12, 0.03, 0.03));
        t.push_back(text("contrast_mask_scheme", "Tone mask base", PRINT, SettingChoices::listed, {"gaussian"},
                         "gaussian", "gaussian"));
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
                        const RenderSettings& settings, const Catalog& catalog) {
    const spk_image input{decoded.rgb.data(), decoded.width, decoded.height, 3};
    const auto params = opening_params(settings, catalog).dump();
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
    return catalog.film(settings.film_stock)->is_positive || std::get<bool>(settings.get("scan_film"));
}

Json wire_params(const RenderSettings& settings, const Catalog& catalog) {
    const Stock* film = catalog.film(settings.film_stock);
    const Stock* paper = catalog.paper(settings.print_stock);
    const bool silver_film = film && film->is_monochrome;
    const bool print_effects = std::get<bool>(settings.get("print_effects"));
    Json wire = Json::object();
    // Every wire row, including the ones still at the engine's default: a
    // session is then fully described by the settings that opened it.
    for (const Row& row : rows())
        if (row.field.wire) wire.set(row.field.key, to_json(settings.get(row.field.key)));
    // Desktop policy matches the macOS session: a slide is already a
    // positive and must bypass negative-to-paper printing. The generic
    // engine API still permits deliberate positive-to-paper experiments.
    wire.set("scan_film", Json((film && film->is_positive) || std::get<bool>(settings.get("scan_film"))));
    // Print Effects is a gate on the wire, so turning it back on restores
    // exactly what was there (Params.swift:756, :759).
    wire.set("glare_active", Json(settings.glare_active && print_effects));
    if (!print_effects) wire.set("preflash_exposure", Json(0.0));
    // The Tone Mask too (Params.swift:763; ToneMaskSection greys while Print
    // Effects is off). macOS also gates it on FeatureFlags.toneMask, false in
    // its builds since the owner's decision of 2026-09-29 (FeatureFlags.swift
    // :43-52); here the rows are live and the QML decides what to offer.
    wire.set("contrast_mask_active", Json(std::get<bool>(settings.get("contrast_mask_active")) && print_effects));
    // The three sub-layers are the colour films' model; nothing on a B&W
    // sheet supports the split (owner, 2026-10-09; Params.swift:744-750).
    wire.set("grain_sublayers_active", Json(std::get<bool>(settings.get("grain_sublayers_active")) && !silver_film));
    // The row is the Grain strength, a multiple of the film's own grain;
    // the wire stops at 2 (Params.swift:789-790).
    const SettingField& grain = row_for("grain_amount").field;
    wire.set("grain_amount",
             Json(std::clamp(settings.grain_amount * own_grain(settings.film_stock), grain.low, grain.high)));
    // Black and white on its paper: the enlarger's pack is sent, because the
    // engine's table has no row for a silver paper and a session coming from a
    // colour pair would keep that pair's (Params.swift:810-820). Multigrade
    // filter 2, from engine/resources_product/paper_grades.json, whose
    // print_exposure is 1, so Print Exposure needs no correction.
    if (silver_film && paper && paper->is_monochrome) {
        wire.set("c_filter_neutral", Json(0.0));
        wire.set("m_filter_neutral", Json(0.0));
        wire.set("y_filter_neutral", Json(68.0));
    }
    return wire;
}

Json opening_params(const RenderSettings& settings, const Catalog& catalog) {
    Json params = Json::object();
    params.set("input_color_space", Json(std::string("ProPhoto RGB")));
    params.set("input_cctf_decoding", Json(false));
    params.set("output_color_space", Json(std::string("sRGB")));
    params.set("output_cctf_encoding", Json(true));
    // EDR maps the print's highlights above 1.0 (pipeline.cpp node_edr), and
    // this host's output is an SDR sRGB frame that spk_to_rgba16 clamps to
    // 1.0: the extended range would only clip. Off, as on a silver paper.
    params.set("extended_dynamic_range", Json(false));
    // Named, not iterated as a temporary: fields() is a reference into it.
    const Json wire = wire_params(settings, catalog);
    for (const auto& [key, value] : wire.fields()) params.set(key, value);
    return params;
}

Json changed_params(const RenderSettings& before, const RenderSettings& after, const Catalog& catalog) {
    const Json was = wire_params(before, catalog);
    const Json now = wire_params(after, catalog);
    Json delta = Json::object();
    // The C API retains carried user controls when loading another stock.
    // Send only changed fields: an unchanged SHOOT field in a paper-only
    // delta would unnecessarily invalidate the cached grain realization, and
    // even an unchanged film_stock invalidates the negative.
    for (const auto& [key, value] : now.fields()) {
        const Json& old = was.at(key);
        if (!old.is_null() && old.dump() == value.dump()) continue;
        delta.set(key, value);
    }
    // Send false too when returning to negative film, otherwise the
    // previous slide's direct-scan mode would survive the stock change.
    if (delta.has("film_stock")) delta.set("scan_film", now.at("scan_film"));
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
spk_session* PreviewHost::session() const noexcept { return impl_->session.get(); }
const io::DecodedRaw& PreviewHost::input() const noexcept { return impl_->decoded; }

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
    // The settings' white balance is applied here, at decode (raw_white_balance.hpp).
    const bool decoded_ok = decode_raw(path, mode, settings, decoded, error);
    require(decoded_ok, "RAW decode: " + error);
    next->timings.decode_ms = elapsed(t);
    next->metadata = decoded.metadata;
    next->decode_timings = decoded.timings;
    t = Clock::now();
    auto session = open_session(impl_->engine.get(), decoded, settings, impl_->catalog);
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
    // A white balance is no wire field: it is the decode, so the file is
    // decoded again and a new negative developed (macOS re-decodes too,
    // Session.swift:2694-2725). open_raw is transactional, as below.
    if (!same_decode(impl_->frame->settings, settings))
        return open_raw(impl_->frame->source, impl_->frame->decode_mode, settings);
    const bool scan_film = validate_settings(settings, impl_->catalog);
    auto next = std::shared_ptr<Frame>(new Frame());
    next->source = impl_->frame->source;
    next->decode_mode = impl_->frame->decode_mode;
    next->settings = settings;
    next->scan_film = scan_film;
    next->metadata = impl_->frame->metadata;
    next->decode_timings = impl_->frame->decode_timings;
    const auto delta = changed_params(impl_->frame->settings, settings, impl_->catalog);
    try {
        auto t = Clock::now();
        if (!impl_->session) {
            // C API settings changes may fail after applying part of their
            // state. Never reuse such a session; rebuild from the retained
            // decoded input on the next request, without decoding the file.
            impl_->session = open_session(impl_->engine.get(), impl_->decoded, settings, impl_->catalog);
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
