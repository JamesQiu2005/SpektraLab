#include "preview_host.hpp"
#include "io/image_writer.hpp"
#include "raw_white_balance.hpp"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <limits>
#include <optional>
#include <set>
#include <stdexcept>
#include <thread>
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
// A product row with a list of choices, or (no list) free text.
Row product(std::string key, std::string label, SettingLayer layer, std::vector<std::string> listed,
            std::string initial) {
    SettingField f{std::move(key), std::move(label), SettingType::text, layer};
    f.choices = listed.empty() ? SettingChoices::free : SettingChoices::listed;
    f.listed = std::move(listed);
    f.initial = initial;
    f.absent = std::move(initial);
    f.wire = false;
    return {std::move(f), {}};
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
        // Film Edge (FilmEdgeSection.swift, FilmEdgeSettings in FilmEdge.swift:
        // 98-133), each at the engine's default, which is also macOS's. What
        // the session resolves -- the edge print, the f-number -- is no row
        // (wire_params). The carrier is the engine's: macOS draws no control
        // for it and leaves it `none` (FilmEdgeSection.swift:597-600).
        std::vector<std::string> formats;
        for (const FilmFormat& f : film_formats()) formats.push_back(f.id);
        t.push_back(boolean("overscan_active", "Film edge", SHOOT, false));
        t.push_back(text("overscan_format", "Film edge format", SHOOT, SettingChoices::listed, formats, "135", "135"));
        t.push_back(text("overscan_mode", "Film edge view", SHOOT, SettingChoices::listed, {"strip", "filed"},
                         "strip", "strip"));
        t.push_back(text("overscan_gate", "Gate", SHOOT, SettingChoices::listed,
                         {"auto", "square", "rounded", "eared", "shouldered", "kicked"}, "auto", "auto"));
        t.push_back(text("overscan_holes", "Holes", SHOOT, SettingChoices::listed, {"white", "black"}, "white", "white"));
        t.push_back(text("overscan_carrier", "Carrier", SHOOT, SettingChoices::listed, {"none", "black", "open"},
                         "none", "none"));
        // The body (per user: a new frame takes the user's) and the advance
        // (per frame); both seeds, integers on the wire (seed_film_edge).
        t.push_back(number("overscan_camera_seed", "Camera body", SHOOT, 0.0, 2147483647.0, 1.0, 1.0));
        t.push_back(number("overscan_frame_seed", "Frame advance", SHOOT, 0.0, 2147483647.0, 1.0, 1.0));
        // 0 is "Auto", the frame seed's draw (FilmEdgeSettings.frameNumber).
        t.push_back(number("overscan_frame_number", "Frame number", SHOOT, 0.0, 99.0, 0.0, 0.0));
        t.push_back(number("overscan_fog", "Edge fog", SHOOT, 0.0, 4.0, 1.0, 1.0));
        t.push_back(number("overscan_leaks", "Spool leaks", SHOOT, 0.0, 4.0, 0.0, 0.0));
        // FilmEdgeSettings.seeded: a frame from before the film edge has none
        // and is given its seeds the first time it is opened.
        t.push_back(product("film_edge_seeded", "Film edge seeded", SHOOT, false));
        // Date Back (DateBackSection.swift, DateBackSettings in FilmEdge.swift:
        // 244-317). macOS draws no inset control ("not here yet"); the rows
        // keep its 3.0 / 2.4 mm, which the engine shares.
        t.push_back(boolean("date_imprint_active", "Date back", SHOOT, false));
        t.push_back(text("date_imprint_style", "Date face", SHOOT, SettingChoices::listed, {"lcd", "dots", "data"},
                         "lcd", "lcd"));
        // `rebate` is the section's "Between" (DateBackPlacement.between).
        t.push_back(text("date_imprint_placement", "Date placement", SHOOT, SettingChoices::listed,
                         {"frame", "rebate"}, "frame", "frame"));
        t.push_back(text("date_imprint_corner", "Date corner", SHOOT, SettingChoices::listed,
                         {"br", "bl", "tr", "tl"}, "br", "br"));
        t.push_back(number("date_imprint_inset_x", "Date inset across (mm)", SHOOT, 0.0, 30.0, 3.0, 3.0));
        t.push_back(number("date_imprint_inset_y", "Date inset up (mm)", SHOOT, 0.0, 30.0, 2.4, 2.4));
        t.push_back(number("date_imprint_size", "Date size", SHOOT, 0.4, 3.0, 1.0, 1.0));
        t.push_back(number("date_imprint_ev", "Date brightness (stops)", SHOOT, -2.0, 8.0, 3.5, 3.5));
        // DateBackOrder (FilmEdge.swift:236-242): "japan" is '26 10 1.
        t.push_back(product("date_back_order", "Date order", SHOOT, {"japan", "us"}, "japan"));
        // DateBackSettings.withData: the shooting data as well as the date.
        t.push_back(product("date_back_with_data", "Shooting data", SHOOT, false));
        // Where the printed date comes from: the EXIF date, or the user's own
        // text (DateBackSettings.customText, README "or a date you type").
        t.push_back(product("date_back_text_source", "Date source", SHOOT, {"exif", "typed"}, "exif"));
        t.push_back(product("date_back_custom_text", "Typed date", SHOOT, {}, ""));
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

struct OpenedSession {
    SessionPtr session{nullptr, &spk_session_release};
    OutputEncoding encoding;
};

// `rgb` is the decode, or the decode cut by the photograph's geometry when
// the settings cut the frame (Film Edge, Date Back on a cropped frame).
OpenedSession open_session(spk_engine* engine, const float* rgb, std::uint32_t width, std::uint32_t height,
                           const RenderSettings& settings, const Catalog& catalog,
                           const std::string& output_color_space, const PhotoInfo& photo) {
    const spk_image input{rgb, width, height, 3};
    const auto params = opening_params(settings, catalog, output_color_space, &photo).dump();
    // The reply is read for one thing: what the session renders into. The
    // request above is not evidence of that (RFC-018 §5.1, AGENTS.md trap 28).
    char* reply_text = nullptr;
    OpenedSession opened;
    opened.session.reset(spk_open(engine, &input, params.c_str(), &reply_text));
    const std::unique_ptr<char, decltype(&spk_string_free)> reply_owner(reply_text, &spk_string_free);
    require(bool(opened.session), "Open image: " + std::string(spk_last_error(engine)));
    require(reply_text != nullptr, "Open image: the engine returned no open reply");
    Json reply;
    std::string error;
    require(Json::parse(reply_text, reply, error), "Open image: unreadable open reply: " + error);
    opened.encoding = output_encoding(reply);
    return opened;
}

// The crop's pixel rectangle, rounded as windows_UI FrameOutput cropPixels.
void crop_pixels(const EngineCut& g, std::uint32_t width, std::uint32_t height, std::uint32_t& left,
                 std::uint32_t& top, std::uint32_t& w, std::uint32_t& h) {
    const auto edge = [](double v, std::uint32_t size, long lo, long hi) {
        return std::clamp(std::lround(v * double(size)), lo, hi);
    };
    const long l = edge(g.x, width, 0, long(width) - 1), t = edge(g.y, height, 0, long(height) - 1);
    const long r = edge(g.x + g.w, width, l + 1, long(width)), b = edge(g.y + g.h, height, t + 1, long(height));
    left = std::uint32_t(l); top = std::uint32_t(t); w = std::uint32_t(r - l); h = std::uint32_t(b - t);
}

// The decode cut by the geometry for the engine, the same picture the editor
// shows (FrameOutput applyGeometry: crop, straighten with zoom to fill at the
// crop's size, clockwise quarter turns, flips in the output axes), on the
// linear float RGB. One pass: each output pixel maps back through the flips,
// the turns and the straightening to a bilinear sample of the crop.
std::vector<float> cut_decode(const io::DecodedRaw& in, const EngineCut& g, std::uint32_t& out_w,
                              std::uint32_t& out_h) {
    require(g.x >= 0 && g.y >= 0 && g.w > 0 && g.h > 0 && g.x + g.w <= 1.0 + 1e-9 && g.y + g.h <= 1.0 + 1e-9 &&
                g.quarter_turns >= 0 && g.quarter_turns <= 3 && std::isfinite(g.straighten_deg) &&
                std::abs(g.straighten_deg) <= 45.0, "Film edge: invalid crop geometry");
    std::uint32_t left = 0, top = 0, cw = 0, ch = 0;
    crop_pixels(g, in.width, in.height, left, top, cw, ch);
    const bool turned = g.quarter_turns % 2 == 1;
    out_w = turned ? ch : cw;
    out_h = turned ? cw : ch;
    std::vector<float> out(std::size_t(out_w) * out_h * 3);
    const double angle = g.straighten_deg * std::acos(-1.0) / 180.0;
    const double cosine = std::cos(angle), sine = std::sin(angle);
    const double zoom = std::max(std::abs(cosine) + std::abs(sine) * ch / cw, std::abs(cosine) + std::abs(sine) * cw / ch);
    const double c = cosine / zoom, s = sine / zoom, cx = (cw - 1) * 0.5, cy = (ch - 1) * 0.5;
    const auto rows = [&](std::uint32_t y0, std::uint32_t y1) {
        for (std::uint32_t Y = y0; Y < y1; ++Y)
            for (std::uint32_t X = 0; X < out_w; ++X) {
                // Undo the flips, then the clockwise turns: (x, y) in the
                // straightened crop, cw x ch.
                const std::uint32_t fx = g.flip_h ? out_w - 1 - X : X, fy = g.flip_v ? out_h - 1 - Y : Y;
                std::uint32_t x = fx, y = fy;
                switch (g.quarter_turns) {
                case 1: x = fy; y = ch - 1 - fx; break;
                case 2: x = cw - 1 - fx; y = ch - 1 - fy; break;
                case 3: x = cw - 1 - fy; y = fx; break;
                default: break;
                }
                float* dst = out.data() + (std::size_t(Y) * out_w + X) * 3;
                if (g.straighten_deg == 0.0) {
                    const float* src = in.rgb.data() + (std::size_t(top + y) * in.width + left + x) * 3;
                    dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[2];
                    continue;
                }
                const double sx = std::clamp(cx + c * (x - cx) + s * (y - cy), 0.0, double(cw - 1));
                const double sy = std::clamp(cy - s * (x - cx) + c * (y - cy), 0.0, double(ch - 1));
                const std::uint32_t x0 = std::uint32_t(sx), y0 = std::uint32_t(sy);
                const std::uint32_t x1 = std::min(x0 + 1, cw - 1), y1 = std::min(y0 + 1, ch - 1);
                const double ax = sx - x0, ay = sy - y0;
                const auto at = [&](std::uint32_t px, std::uint32_t py) {
                    return in.rgb.data() + (std::size_t(top + py) * in.width + left + px) * 3;
                };
                const float *a = at(x0, y0), *b = at(x1, y0), *d = at(x0, y1), *e = at(x1, y1);
                for (int k = 0; k < 3; ++k)
                    dst[k] = float((a[k] + (b[k] - a[k]) * ax) * (1 - ay) + (d[k] + (e[k] - d[k]) * ax) * ay);
            }
    };
    const std::uint32_t workers = std::clamp(std::thread::hardware_concurrency(), 1u, 8u);
    std::vector<std::thread> threads;
    const std::uint32_t band = (out_h + workers - 1) / workers;
    for (std::uint32_t i = 0; i < workers; ++i) {
        const std::uint32_t y0 = i * band, y1 = std::min(out_h, y0 + band);
        if (y0 < y1) threads.emplace_back(rows, y0, y1);
    }
    for (auto& t : threads) t.join();
    return out;
}

// The whole decode undeveloped, for framing in the gate: box-downsampled to
// a long edge of at most 2048, linear ProPhoto (D50) to sRGB (D65, Bradford),
// its mean luminance placed at 18 %, sRGB encoded. Only a guide to frame
// with; the print is the engine's.
std::shared_ptr<const Frame::SourcePreview> source_preview(const io::DecodedRaw& in) {
    auto preview = std::make_shared<Frame::SourcePreview>();
    const std::uint32_t k = std::max(1u, (std::max(in.width, in.height) + 2047) / 2048);
    preview->width = std::max(1u, in.width / k);
    preview->height = std::max(1u, in.height / k);
    std::vector<float> linear(std::size_t(preview->width) * preview->height * 3);
    double mean = 0.0;
    for (std::uint32_t y = 0; y < preview->height; ++y)
        for (std::uint32_t x = 0; x < preview->width; ++x) {
            double sum[3] = {};
            for (std::uint32_t j = 0; j < k; ++j) {
                const float* row = in.rgb.data() + (std::size_t(y * k + j) * in.width + x * k) * 3;
                for (std::uint32_t i = 0; i < k * 3; ++i) sum[i % 3] += row[i];
            }
            float* p = linear.data() + (std::size_t(y) * preview->width + x) * 3;
            for (int c = 0; c < 3; ++c) p[c] = float(sum[c] / double(k * k));
            mean += 0.2880402 * p[0] + 0.7118741 * p[1] + 0.0000857 * p[2];
        }
    mean /= double(preview->width) * preview->height;
    const double gain = std::clamp(mean > 0.0 ? 0.18 / mean : 1.0, 0.125, 32.0);
    constexpr double m[9] = {2.03406, -0.72733, -0.30674, -0.22881, 1.23173, -0.00292, -0.00857, -0.15329, 1.16186};
    const auto encode = [](double v) {
        v = std::clamp(v, 0.0, 1.0);
        v = v <= 0.0031308 ? 12.92 * v : 1.055 * std::pow(v, 1.0 / 2.4) - 0.055;
        return std::uint8_t(std::lround(v * 255.0));
    };
    preview->bgra8.resize(std::size_t(preview->width) * preview->height * 4);
    for (std::size_t i = 0, n = std::size_t(preview->width) * preview->height; i < n; ++i) {
        const float* p = linear.data() + i * 3;
        std::uint8_t* q = preview->bgra8.data() + i * 4;
        for (int c = 0; c < 3; ++c)
            q[2 - c] = encode(gain * (m[3 * c] * p[0] + m[3 * c + 1] * p[1] + m[3 * c + 2] * p[2]));
        q[3] = 255;
    }
    return preview;
}

std::string read_overscan_geometry(spk_session* session) {
    char* text = nullptr;
    if (spk_overscan_geometry(session, &text) != SPK_OK || !text) return "{\"valid\":false}";
    std::string out(text);
    spk_string_free(text);
    return out;
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
        if (field.choices == SettingChoices::free) {
            // What a date back's faces can print: one short line of ASCII.
            if (v.size() > kFreeTextMax ||
                std::any_of(v.begin(), v.end(), [](unsigned char c) { return c < 0x20 || c > 0x7E; }))
                return field.label + " must be at most " + std::to_string(kFreeTextMax) +
                       " printable ASCII characters";
        } else if (field.choices == SettingChoices::listed) {
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

// --- Film Edge and Date Back ------------------------------------------------

const std::vector<FilmFormat>& film_formats() {
    // FilmEdgeFormat (FilmEdge.swift:9-81): the gate held level, the film it
    // runs on; its words and costs (FilmEdgeSection.swift:547-622). Which
    // date faces a camera draws: 135 and 120 all three, panoramic none
    // (FilmEdgeFormat.draws); 120 prints them in the margin (printsInMargin).
    static const std::vector<FilmFormat> formats = [] {
        const std::string x = "\xC3\x97";  // the multiplication sign
        std::vector<FilmFormat> f;
        const auto add = [&](std::string id, std::string title, std::string group, double l, double s,
                             std::string gauge, std::string gate, std::string ratio, double strip, double filed) {
            FilmFormat fmt{std::move(id), std::move(title), group, l, s, gauge, gauge == "135",
                           std::move(gate), std::move(ratio), strip, filed};
            fmt.prints_in_margin = group == "120";
            fmt.has_date_back = group != "panoramic";
            f.push_back(std::move(fmt));
        };
        add("135", "135", "135", 36, 24, "135", "36 " + x + " 24", "3:2", 1.52, 1.15);
        add("135_half", "Half", "135", 24, 18, "135", "18 " + x + " 24", "3:4", 1.54, 1.20);
        add("120_645", "645", "120", 56, 41.5, "120", "56 " + x + " 41.5", "1.35", 1.20, 1.09);
        add("120_6x6", "6" + x + "6", "120", 56, 56, "120", "56 " + x + " 56", "1:1", 1.17, 1.07);
        add("120_6x7", "6" + x + "7", "120", 69.5, 56, "120", "56 " + x + " 69.5", "1.24", 1.15, 1.07);
        add("120_6x8", "6" + x + "8", "120", 76, 56, "120", "56 " + x + " 76", "1.36", 1.15, 1.06);
        add("120_6x9", "6" + x + "9", "120", 84, 56, "120", "56 " + x + " 84", "3:2", 1.14, 1.06);
        add("135_xpan", "XPan", "panoramic", 65, 24, "135", "24 " + x + " 65", "2.7", 1.50, 1.12);
        add("120_6x12", "6" + x + "12", "panoramic", 112, 56, "120", "56 " + x + " 112", "2:1", 1.13, 1.06);
        add("120_6x17", "6" + x + "17", "panoramic", 168, 56, "120", "56 " + x + " 168", "3:1", 1.12, 1.05);
        return f;
    }();
    return formats;
}

const FilmFormat* film_format(std::string_view id) {
    for (const FilmFormat& f : film_formats())
        if (f.id == id) return &f;
    return nullptr;
}

bool EngineCut::identity() const {
    return x == 0 && y == 0 && w == 1 && h == 1 && quarter_turns == 0 && !flip_h && !flip_v && straighten_deg == 0;
}

void cut_size(const EngineCut& cut, std::uint32_t width, std::uint32_t height, std::uint32_t& out_width,
              std::uint32_t& out_height) {
    std::uint32_t left = 0, top = 0, w = width, h = height;
    if (width && height) crop_pixels(cut, width, height, left, top, w, h);
    const bool turned = cut.quarter_turns % 2 == 1;
    out_width = turned ? h : w;
    out_height = turned ? w : h;
}

namespace {
std::string text_of(const RenderSettings& s, const char* key) { return std::get<std::string>(s.get(key)); }
bool bool_of(const RenderSettings& s, const char* key) { return std::get<bool>(s.get(key)); }
double number_of(const RenderSettings& s, const char* key) { return std::get<double>(s.get(key)); }
// "1.8", "2", "11": one decimal without a trailing ".0" (ShootingData.trimmed).
std::string trimmed(double v) {
    char b[32];
    std::snprintf(b, sizeof b, "%.1f", v);
    std::string s = b;
    if (s.size() > 2 && s.compare(s.size() - 2, 2, ".0") == 0) s.resize(s.size() - 2);
    return s;
}
}  // namespace

const FilmFormat* date_back_camera(const RenderSettings& settings, const PhotoInfo& photo) {
    // A pair is a half-frame camera's, with or without the film around it
    // (Session+FilmEdge.swift:288-289).
    if (photo.pair.active) return film_format("135_half");
    if (bool_of(settings, "overscan_active")) return film_format(text_of(settings, "overscan_format"));
    // The Film Format frame, both sides: the wire's long edge and the
    // photograph's aspect (Session.filmFormatSidesMM); a 3:2 frame before
    // its decode is known.
    const double w = photo.decode_width, h = photo.decode_height;
    const double aspect = w > 0 && h > 0 ? std::max(w, h) / std::min(w, h) : 1.5;
    const double long_mm = settings.film_format_mm, short_mm = long_mm / std::max(aspect, 1.0);
    for (const char* id : {"135", "135_half", "120_645"}) {
        const FilmFormat* f = film_format(id);
        if (std::abs(f->long_mm - long_mm) <= 1.0 && std::abs(f->short_mm - short_mm) <= 1.0) return f;
    }
    return nullptr;
}

bool date_back_prints(const RenderSettings& settings, const PhotoInfo& photo, std::string_view face) {
    const FilmFormat* camera = date_back_camera(settings, photo);
    if (!camera || !camera->has_date_back) return false;
    return face == "data" || camera->prints_in_margin ? bool_of(settings, "overscan_active") : true;
}

bool date_back_effective(const RenderSettings& settings, const PhotoInfo& photo) {
    if (!bool_of(settings, "date_imprint_active")) return false;
    const std::string face = text_of(settings, "date_imprint_style");
    if (!date_back_prints(settings, photo, face)) return false;
    return face == "data" || text_of(settings, "date_imprint_placement") == "frame" ||
           bool_of(settings, "overscan_active");
}

bool date_back_prints_data(const RenderSettings& settings, const PhotoInfo& photo) {
    return bool_of(settings, "date_back_with_data") && text_of(settings, "date_imprint_style") != "data" &&
           date_back_prints(settings, photo, "data");
}

bool cuts_frame(const RenderSettings& settings, const PhotoInfo& photo) {
    // A pair's piece is already the gate's shape: there is no crop to hold
    // (Session.filmEdgeWillChange, Session+FilmEdge.swift:400-405).
    if (photo.pair.active) return false;
    return bool_of(settings, "overscan_active") ||
           (date_back_effective(settings, photo) && !photo.geometry.identity());
}

std::string edge_text(const Catalog& catalog, std::string_view film, std::string_view gauge) {
    // The film's own words where it prints something other than its name,
    // read off the strips (Session.edgeText, Session+FilmEdge.swift:217-238).
    struct Own { const char* id; const char* on135; const char* on120; };
    static constexpr Own own[] = {
        {"kodak_gold_200", "KODAK GB 200-7", "KODAK 200"},
        {"kodak_portra_800", "KODAK PORTRA 800-3", "KODAK PORTRA 800"},
        {"kodak_portra_800_push1", "KODAK PORTRA 800-3", "KODAK PORTRA 800"},
        {"kodak_portra_800_push2", "KODAK PORTRA 800-3", "KODAK PORTRA 800"},
        {"kodak_ultramax_400", "KODAK GC 400", "KODAK GC 400"},
        {"kodak_ektachrome_100", "KODAK E100", "KODAK E100"},
        {"fujifilm_c200", "FUJI 200", "FUJI 200"},
        {"fujifilm_xtra_400", "S-400", "FUJI S-400"},
        {"fujifilm_pro_400h", "PRO400H", "FUJI PRO400H"},
        {"fujifilm_provia_100f", "FUJI RDPIII", "FUJI RDPIII"},
        {"fujifilm_velvia_100", "RVP100", "FUJI RVP100"},
        {"kodak_vision3_50d", "EASTMAN 5203", "EASTMAN 5203"},
        {"kodak_vision3_250d", "EASTMAN 5207", "EASTMAN 5207"},
        {"kodak_vision3_200t", "EASTMAN 5213", "EASTMAN 5213"},
        {"kodak_vision3_500t", "EASTMAN 5219", "EASTMAN 5219"},
        {"kodak_tri_x_400", "KODAK 400TX", "KODAK 400TX"},
        {"kodak_tmax_100", "KODAK 100TMX", "KODAK 100TMX"},
        {"fujifilm_neopan_acros_100_ii", "FUJI 100 ACROS II", "FUJI 100 ACROS II"},
        {"ilford_hp5_plus_400", "ILFORD HP5 PLUS", "ILFORD HP5 PLUS"},
    };
    for (const Own& o : own)
        if (film == o.id) return gauge == "120" ? o.on120 : o.on135;
    const Stock* stock = catalog.film(film);
    if (!stock) return {};
    // The name in capitals, without a "(Push 1)": a push is processing.
    std::string name = stock->label.substr(0, stock->label.find('('));
    while (!name.empty() && name.back() == ' ') name.pop_back();
    while (!name.empty() && name.front() == ' ') name.erase(name.begin());
    for (char& c : name) c = char(std::toupper(static_cast<unsigned char>(c)));
    return name;
}

std::string date_text(const io::ShootingData& shooting, std::string_view order) {
    if (shooting.year == 0) return {};
    char yy[8];
    std::snprintf(yy, sizeof yy, "'%02d", ((shooting.year % 100) + 100) % 100);
    const std::string m = std::to_string(shooting.month), d = std::to_string(shooting.day);
    return order == "us" ? m + " " + d + " " + yy : std::string(yy) + " " + m + " " + d;
}

std::string data_text(const io::ShootingData& shooting) {
    std::vector<std::string> fields;
    if (shooting.exposure_time > 0) {
        const double t = shooting.exposure_time;
        fields.push_back(t >= 1 ? trimmed(t) + "s" : "1/" + std::to_string(std::lround(1.0 / t)));
    }
    if (shooting.f_number > 0) fields.push_back("F" + trimmed(shooting.f_number));
    if (shooting.exposure_program >= 1 && shooting.exposure_program <= 4)
        fields.push_back(std::string(1, "MPAS"[shooting.exposure_program - 1]));
    if (shooting.has_bias) {
        const double r = std::round(shooting.exposure_bias * 10.0) / 10.0;
        if (r != 0.0) {
            char b[16];
            std::snprintf(b, sizeof b, "%+.1f", r);
            fields.push_back(b);
        }
    }
    if (shooting.focal_35mm > 0) fields.push_back(std::to_string(std::lround(shooting.focal_35mm)) + "mm");
    // Nikon's between-frames line holds 22: fields drop from the right.
    const auto joined = [&] {
        std::string s;
        for (const auto& f : fields) s += (s.empty() ? "" : " ") + f;
        return s;
    };
    while (joined().size() > 22) fields.pop_back();
    return joined();
}

std::string printed_date_text(const RenderSettings& settings, const io::ShootingData& shooting) {
    if (text_of(settings, "date_back_text_source") == "typed") return text_of(settings, "date_back_custom_text");
    return text_of(settings, "date_imprint_style") == "data" ? data_text(shooting)
                                                              : date_text(shooting, text_of(settings, "date_back_order"));
}

double gate_ratio(const RenderSettings& settings, bool landscape) {
    const FilmFormat* f = film_format(text_of(settings, "overscan_format"));
    const double l = f ? f->long_mm : 36.0, s = f ? f->short_mm : 24.0;
    return landscape ? l / s : s / l;
}

bool gate_shaped(const EngineCut& cut, const RenderSettings& settings, std::uint32_t width, std::uint32_t height) {
    const double pw = cut.w * width, ph = cut.h * height;
    if (!(pw > 0 && ph > 0)) return false;
    return std::abs((pw / ph) / gate_ratio(settings, pw >= ph) - 1.0) <= 0.02;
}

EngineCut gate_framed(const EngineCut& cut, const RenderSettings& settings, std::uint32_t width,
                      std::uint32_t height, int landscape) {
    if (width == 0 || height == 0) return cut;
    const double W = width, H = height;
    const double pw = cut.w * W, ph = cut.h * H;
    const double ratio = gate_ratio(settings, landscape < 0 ? pw >= ph : landscape > 0);
    // Keep the area, then fit inside the frame (Geometry.constrained).
    const double area = std::max(pw * ph, 1.0);
    double nw = std::sqrt(area * ratio), nh = nw / ratio;
    const double fit = std::min({1.0, W / nw, H / nh});
    nw *= fit;
    nh *= fit;
    EngineCut out = cut;
    out.w = std::min(1.0, nw / W);
    out.h = std::min(1.0, nh / H);
    out.x = std::clamp(cut.x + cut.w / 2 - out.w / 2, 0.0, 1.0 - out.w);
    out.y = std::clamp(cut.y + cut.h / 2 - out.h / 2, 0.0, 1.0 - out.h);
    return out;
}

bool per_photo_setting(std::string_view key) {
    return key.starts_with("overscan_") || key.starts_with("date_imprint_") || key.starts_with("date_back_") ||
           key == "film_edge_seeded";
}

RenderSettings synced_settings(const RenderSettings& from, const RenderSettings& recipient) {
    RenderSettings out = from;
    for (const SettingField& field : setting_fields())
        if (per_photo_setting(field.key)) out.set(field.key, recipient.get(field.key));
    return out;
}

std::uint32_t frame_seed_for(std::string_view path_utf8) {
    // macOS hashes the path with SHA-256 (Session.frameSeed); any stable,
    // well-spread hash serves: FNV-1a over the path, ASCII case folded since
    // Windows paths are case-insensitive, kept to the wire's positive range.
    std::uint32_t hash = 2166136261u;
    for (unsigned char c : path_utf8) {
        hash ^= std::uint32_t(c >= 'A' && c <= 'Z' ? c + 32 : (c == '\\' ? '/' : c));
        hash *= 16777619u;
    }
    return hash & 0x7FFFFFFFu;
}

void seed_film_edge(RenderSettings& settings, std::string_view path_utf8, int index, int body_seed) {
    settings.set("overscan_frame_seed", double(frame_seed_for(path_utf8)));
    settings.set("overscan_camera_seed", double(std::clamp(body_seed, 0, 2147483647)));
    settings.set("overscan_frame_number", index >= 0 ? double(index % 99 + 1) : 0.0);
    settings.set("film_edge_seeded", true);
}

Json wire_params(const RenderSettings& settings, const Catalog& catalog, const PhotoInfo* photo) {
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
    // Film Edge and Date Back (FilmEdgeSettings.wire, DateBackSettings.wire,
    // FilmEdge.swift:194-214, 375-404). The seeds and the frame number are
    // integers on the wire.
    const PhotoInfo unknown;
    const PhotoInfo& frame = photo ? *photo : unknown;
    for (const char* key : {"overscan_camera_seed", "overscan_frame_seed", "overscan_frame_number"})
        wire.set(key, Json(std::round(number_of(settings, key))));
    // What the session resolves for the engine (Session.resolvedFilmEdge):
    // the stock's edge print and the lens's f-number, while the film edge is on.
    const bool edge = bool_of(settings, "overscan_active");
    const bool pair = frame.pair.active;
    const FilmFormat* format = film_format(pair ? std::string("135_half") : text_of(settings, "overscan_format"));
    wire.set("overscan_edge_text",
             Json(edge && format ? edge_text(catalog, settings.film_stock, format->gauge) : std::string()));
    wire.set("overscan_f_number", Json(edge ? std::clamp(frame.shooting.f_number, 0.0, 64.0) : 0.0));
    const bool date = date_back_effective(settings, frame);
    wire.set("date_imprint_active", Json(date));
    std::string printed, data;
    if (date) {
        const FilmFormat* camera = date_back_camera(settings, frame);
        // The engine reads the film's direction from the camera's format,
        // with or without the film edge around it.
        if (!edge) wire.set("overscan_format", Json(camera->id));
        printed = printed_date_text(settings, frame.shooting);
        if (date_back_prints_data(settings, frame)) data = data_text(frame.shooting);
        // The date alone on a cut frame keeps its size and insets in the
        // picture and the grain its pitch (FilmParams.wireFilmFormatMM and
        // dateScale, FilmEdge.swift:423-433): film_format_mm is the cut's
        // long edge, the date scaled by the cut against the camera's frame.
        double scale = 1.0;
        if (!edge && !frame.geometry.identity() && frame.decode_width && frame.decode_height) {
            std::uint32_t cw = 0, ch = 0;
            cut_size(frame.geometry, frame.decode_width, frame.decode_height, cw, ch);
            const double cut_mm = settings.film_format_mm * double(std::max(cw, ch)) /
                                  double(std::max(frame.decode_width, frame.decode_height));
            const SettingField& mm = row_for("film_format_mm").field;
            wire.set("film_format_mm", Json(std::clamp(cut_mm, mm.low, mm.high)));
            scale = std::clamp(cut_mm / camera->long_mm, 0.05, 1.0);
        }
        // Data between half frames has only the 1 mm gap (answer B19).
        double size = std::clamp(number_of(settings, "date_imprint_size"), 0.4, 3.0);
        if (text_of(settings, "date_imprint_style") == "data" && camera->id == "135_half") size = std::min(size, 1.0);
        wire.set("date_imprint_size", Json(std::clamp(size * scale, 0.4, 3.0)));
        wire.set("date_imprint_inset_x", Json(std::clamp(number_of(settings, "date_imprint_inset_x") * scale, 0.0, 30.0)));
        wire.set("date_imprint_inset_y", Json(std::clamp(number_of(settings, "date_imprint_inset_y") * scale, 0.0, 30.0)));
    }
    wire.set("date_imprint_text", Json(printed));
    wire.set("date_imprint_data_text", Json(data));
    if (pair) {
        // A half-frame pair (FilmEdge.swift:194-214, 396-402; Params.swift
        // pairPlacementWire, :623-635): 135 half exposed twice on one strip,
        // or the piece itself when only the date asks for the camera; each
        // frame with its own date and its own Scene Placement past the split.
        if (edge || date) {
            wire.set("overscan_format", Json(std::string("135_half")));
            wire.set("overscan_pair", Json(true));
        }
        std::string second;
        if (date) {
            second = text_of(settings, "date_back_text_source") == "typed" ? text_of(settings, "date_back_custom_text")
                   : text_of(settings, "date_imprint_style") == "data"
                       ? data_text(frame.pair.second)
                       : date_text(frame.pair.second, text_of(settings, "date_back_order"));
        }
        wire.set("date_imprint_text_b", Json(second));
        const PairLatitude& b = frame.pair.latitude_b;
        wire.set("scene_latitude_split", Json(std::clamp(frame.pair.split, 0.0, 1.0)));
        wire.set("scene_latitude_b_active", Json(b.active));
        wire.set("scene_latitude_b_highlight_knee", Json(std::clamp(b.highlight_knee, -24.0, 24.0)));
        wire.set("scene_latitude_b_highlight_room", Json(std::clamp(b.highlight_room, 0.0, 24.0)));
        wire.set("scene_latitude_b_shadow_knee", Json(std::clamp(b.shadow_knee, -24.0, 24.0)));
        wire.set("scene_latitude_b_shadow_room", Json(std::clamp(b.shadow_room, 0.0, 24.0)));
    }
    return wire;
}

Json opening_params(const RenderSettings& settings, const Catalog& catalog, const std::string& output_color_space,
                    const PhotoInfo* photo) {
    Json params = Json::object();
    params.set("input_color_space", Json(std::string("ProPhoto RGB")));
    params.set("input_cctf_decoding", Json(false));
    params.set("output_color_space", Json(output_color_space));
    params.set("output_cctf_encoding", Json(true));
    // EDR maps the print's highlights above 1.0 (pipeline.cpp node_edr), and
    // this host's output is an SDR sRGB frame that spk_to_rgba16 clamps to
    // 1.0: the extended range would only clip. Off, as on a silver paper.
    params.set("extended_dynamic_range", Json(false));
    // Named, not iterated as a temporary: fields() is a reference into it.
    const Json wire = wire_params(settings, catalog, photo);
    for (const auto& [key, value] : wire.fields()) params.set(key, value);
    return params;
}

Json changed_params(const RenderSettings& before, const RenderSettings& after, const Catalog& catalog,
                    const PhotoInfo* photo) {
    const PhotoInfo unknown;
    return changed_params(before, after, catalog, photo ? *photo : unknown, photo ? *photo : unknown);
}

bool same_piece(const PairInput& a, const PairInput& b) {
    if (a.spacing_mm != b.spacing_mm || a.turned != b.turned) return false;
    for (int side = 0; side < 2; ++side) {
        const auto &x = a.holes[side], &y = b.holes[side];
        if (bool(x) != bool(y)) return false;
        if (!x) continue;
        PairHole p = *x, q = *y;
        p.print.reset();
        q.print.reset();
        if (!(p == q)) return false;
    }
    return true;
}

Json changed_params(const RenderSettings& before, const RenderSettings& after, const Catalog& catalog,
                    const PhotoInfo& photo_before, const PhotoInfo& photo_after) {
    const Json was = wire_params(before, catalog, &photo_before);
    const Json now = wire_params(after, catalog, &photo_after);
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

OutputEncoding output_encoding(const Json& open_reply) {
    const auto member = [](const Json* object, const char* key) -> const Json* {
        return object && object->is_object() && object->has(key) ? &object->at(key) : nullptr;
    };
    const Json* params = member(&open_reply, "params");
    const Json* space = member(params, "output_color_space");
    const Json* encoded = member(params, "output_cctf_encoding");
    require(space && space->is_string() && !space->as_string().empty(),
            "Open image: the open reply does not say which colour space the session renders into");
    require(encoded && encoded->is_bool(),
            "Open image: the open reply does not say whether the output is transfer-encoded");
    return {space->as_string(), encoded->as_bool()};
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
    HostOptions options;
    Catalog catalog;
    double engine_create_ms = 0.0;
    EnginePtr engine{nullptr, &spk_engine_destroy};
    // Declaration order makes session release precede engine destruction.
    SessionPtr session{nullptr, &spk_session_release};
    // What `session` renders into, from its open reply.
    OutputEncoding encoding;
    // Retained only for reopening after a failed settings/render operation.
    // Ordinary parameter edits reuse the current GPU source and negative.
    io::DecodedRaw decoded;
    FramePtr frame;
    // The geometry the session's picture was cut with (Film Edge, Date Back),
    // or none for the whole decode; and the decode's undeveloped preview,
    // made the first time a frame of it is cut.
    std::optional<EngineCut> session_cut;
    std::shared_ptr<const Frame::SourcePreview> preview;
    // A half-frame pair (render_pair): each frame's picture -- decoded with
    // its own white balance and cut by its own geometry -- kept while it is in
    // a hole, so a step that changes neither (a placement, an exposure, the
    // gap, the other frame) composes without decoding again; most recent
    // first, two holes and a spare (PairComposer.Rendered). The meter's
    // readings per picture and intent. While `pair` is set the session holds
    // that piece, opened with `pair_photo`.
    struct HolePicture {
        std::string key;
        std::shared_ptr<const PairPicture> picture;
        io::RawMetadata metadata;
    };
    std::vector<HolePicture> holes;
    std::map<std::string, double> meters;
    std::optional<PairInput> pair;
    fs::path pair_identity;
    PhotoInfo pair_photo;
    PairLayout pair_layout;
};

namespace {
// What the engine is handed for these settings and this geometry: whether
// the frame is cut, the geometry it is cut with (held at the gate's shape by
// a film edge, as Session.holdFilmEdgeCrop does before a develop), and the
// frame's facts for wire_params.
struct EngineInput {
    PhotoInfo photo;
    bool cut = false;
};
EngineInput engine_input(const RenderSettings& settings, const io::DecodedRaw& decoded, const EngineCut& geometry) {
    EngineInput in;
    in.photo.shooting = decoded.metadata.shooting;
    in.photo.decode_width = decoded.width;
    in.photo.decode_height = decoded.height;
    in.photo.geometry = geometry;
    in.cut = cuts_frame(settings, in.photo);
    if (in.cut && std::get<bool>(settings.get("overscan_active")) &&
        !gate_shaped(geometry, settings, decoded.width, decoded.height))
        in.photo.geometry = gate_framed(geometry, settings, decoded.width, decoded.height);
    return in;
}

// --- half-frame pairs -------------------------------------------------------

// Everything a hole's picture is made of (PairComposer.renderKey): the file as
// it is on disk, the decode and the frame's own geometry -- not where the
// picture sits under its hole or how it is exposed, which compose.
std::string hole_key(const PairHole& hole, DecodeMode mode) {
    std::error_code ec;
    const auto size = fs::file_size(hole.source, ec);
    const auto stamp = fs::last_write_time(hole.source, ec).time_since_epoch().count();
    const WhiteBalance wb = white_balance(hole.decode);
    const EngineCut& g = hole.geometry;
    char tail[256];
    std::snprintf(tail, sizeof tail, "|%llu|%lld|%d|%s|%.6g|%.6g|%.9g,%.9g,%.9g,%.9g,%d,%d,%d,%.9g",
                  static_cast<unsigned long long>(ec ? 0 : size), static_cast<long long>(stamp), int(mode),
                  wb.mode.c_str(), wb.as_shot() ? 0.0 : wb.temperature, wb.as_shot() ? 0.0 : wb.tint, g.x, g.y, g.w, g.h,
                  g.quarter_turns, int(g.flip_h), int(g.flip_v), g.straighten_deg);
    return utf8(fs::absolute(hole.source)) + tail;
}

// What the meter chooses for one picture alone (Session.pairExposure,
// :4440-4457): the picture small, the frame's own intent, no film edge, no
// date, no placement, a half frame's 24 mm, through spk_solve "exposure".
double meter_picture(spk_engine* engine, const PairPicture& picture, const PairHole& hole, RenderSettings settings,
                     const Catalog& catalog, const std::string& output_color_space) {
    const std::uint32_t k = std::max(1u, (std::max(picture.width, picture.height) + 1023) / 1024);
    const std::uint32_t w = std::max(1u, picture.width / k), h = std::max(1u, picture.height / k);
    std::vector<float> small(std::size_t(w) * h * 3);
    for (std::uint32_t y = 0; y < h; ++y)
        for (std::uint32_t x = 0; x < w; ++x) {
            double sum[3] = {};
            for (std::uint32_t j = 0; j < k; ++j) {
                const float* row = picture.rgb.data() + (std::size_t(y * k + j) * picture.width + x * k) * 3;
                for (std::uint32_t i = 0; i < k * 3; ++i) sum[i % 3] += row[i];
            }
            for (int c = 0; c < 3; ++c) small[(std::size_t(y) * w + x) * 3 + c] = float(sum[c] / double(k * k));
        }
    settings.set("auto_exposure", true);
    settings.set("auto_exposure_method", hole.meter_method);
    settings.film_exposure_ev = 0;
    settings.film_format_mm = kHoleAcrossMM;
    for (const char* key : {"overscan_active", "date_imprint_active", "scene_latitude_active"}) settings.set(key, false);
    auto opened = open_session(engine, small.data(), w, h, settings, catalog, output_color_space, PhotoInfo{});
    char* out = nullptr;
    double ev = 0.0;
    if (spk_solve(opened.session.get(), "exposure", &out) == SPK_OK && out) {
        Json reply;
        std::string error;
        if (Json::parse(out, reply, error)) ev = reply.at("solved_params").at("exposure_compensation_ev").as_double(0.0);
    }
    if (out) spk_string_free(out);
    return std::isfinite(ev) ? ev : 0.0;
}
}  // namespace

PreviewHost::PreviewHost(const fs::path& resources, HostOptions options) : impl_(std::make_unique<Impl>()) {
    impl_->options = std::move(options);
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
const io::DecodedRaw& PreviewHost::decoded() const noexcept { return impl_->decoded; }

FramePtr PreviewHost::open_raw(const fs::path& source, DecodeMode mode, const RenderSettings& settings,
                               const EngineCut& geometry) {
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
    const EngineInput input = engine_input(settings, decoded, geometry);
    std::vector<float> cut_rgb;
    std::uint32_t pw = decoded.width, ph = decoded.height;
    if (input.cut) cut_rgb = cut_decode(decoded, input.photo.geometry, pw, ph);
    auto opened = open_session(impl_->engine.get(), input.cut ? cut_rgb.data() : decoded.rgb.data(), pw, ph,
                               settings, impl_->catalog, impl_->options.output_color_space, input.photo);
    cut_rgb = {};
    next->timings.open_ms = elapsed(t);
    next->encoding = opened.encoding;
    t = Clock::now();
    const auto status = spk_render(opened.session.get(), "full", &next->result_);
    require(status == SPK_OK, "Render: " + std::string(spk_last_error(impl_->engine.get())));
    next->timings.render_ms = elapsed(t);
    next->timings.engine_render_ms = next->result_.elapsed_ms;
    if (impl_->options.bgra8_display) {
        t = Clock::now();
        next->bgra8 = rgba16_to_bgra8(next->result_);
        next->timings.display_ms = elapsed(t);
    }
    next->geometry = input.photo.geometry;
    next->cut = input.cut;
    next->decode_width = decoded.width;
    next->decode_height = decoded.height;
    next->picture_width = pw;
    next->picture_height = ph;
    next->overscan_geometry = read_overscan_geometry(opened.session.get());
    auto preview = input.cut ? source_preview(decoded) : nullptr;
    next->source_preview = preview;
    // Commit only after all allocations and GPU/CPU work succeeded.
    impl_->session = std::move(opened.session);
    impl_->encoding = opened.encoding;
    impl_->session_cut = input.cut ? std::optional<EngineCut>(input.photo.geometry) : std::nullopt;
    impl_->preview = std::move(preview);
    impl_->decoded = std::move(decoded);
    impl_->frame = next;
    // A photograph replaces a pair: its pictures are not kept behind it.
    impl_->pair.reset();
    impl_->holes.clear();
    next->timings.total_ms = elapsed(started);
    return next;
}

FramePtr PreviewHost::render(const RenderSettings& settings, const EngineCut& geometry) {
    const auto started = Clock::now();
    require(bool(impl_->frame), "Open a RAW image before rendering");
    require(!impl_->pair, "A half-frame pair renders through render_pair");
    // A white balance is no wire field: it is the decode, so the file is
    // decoded again and a new negative developed (macOS re-decodes too,
    // Session.swift:2694-2725). open_raw is transactional, as below.
    if (!same_decode(impl_->frame->settings, settings))
        return open_raw(impl_->frame->source, impl_->frame->decode_mode, settings, geometry);
    const bool scan_film = validate_settings(settings, impl_->catalog);
    auto next = std::shared_ptr<Frame>(new Frame());
    next->source = impl_->frame->source;
    next->decode_mode = impl_->frame->decode_mode;
    next->settings = settings;
    next->scan_film = scan_film;
    next->metadata = impl_->frame->metadata;
    next->decode_timings = impl_->frame->decode_timings;
    const EngineInput input = engine_input(settings, impl_->decoded, geometry);
    const auto wanted_cut = input.cut ? std::optional<EngineCut>(input.photo.geometry) : std::nullopt;
    const auto delta = changed_params(impl_->frame->settings, settings, impl_->catalog, &input.photo);
    std::uint32_t pw = impl_->decoded.width, ph = impl_->decoded.height;
    if (impl_->session && wanted_cut == impl_->session_cut) {
        pw = impl_->frame->picture_width;
        ph = impl_->frame->picture_height;
    }
    try {
        auto t = Clock::now();
        if (!impl_->session || wanted_cut != impl_->session_cut) {
            // C API settings changes may fail after applying part of their
            // state. Never reuse such a session; rebuild from the retained
            // decoded input on the next request, without decoding the file.
            // A new cut is a new picture for the engine: the same rebuild.
            impl_->session.reset();
            std::vector<float> cut_rgb;
            if (input.cut) cut_rgb = cut_decode(impl_->decoded, input.photo.geometry, pw, ph);
            auto opened = open_session(impl_->engine.get(), input.cut ? cut_rgb.data() : impl_->decoded.rgb.data(),
                                       pw, ph, settings, impl_->catalog, impl_->options.output_color_space, input.photo);
            impl_->session = std::move(opened.session);
            impl_->encoding = opened.encoding;
            impl_->session_cut = wanted_cut;
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
        // A delta never carries output_color_space (it is no settings row),
        // so the space the session was opened with still holds.
        next->encoding = impl_->encoding;
        if (impl_->options.bgra8_display) {
            t = Clock::now();
            next->bgra8 = rgba16_to_bgra8(next->result_);
            next->timings.display_ms = elapsed(t);
        }
        next->overscan_geometry = read_overscan_geometry(impl_->session.get());
        if (input.cut && !impl_->preview) impl_->preview = source_preview(impl_->decoded);
    } catch (...) {
        impl_->session.reset();
        throw;
    }
    next->geometry = input.photo.geometry;
    next->cut = input.cut;
    next->decode_width = impl_->decoded.width;
    next->decode_height = impl_->decoded.height;
    next->picture_width = pw;
    next->picture_height = ph;
    next->source_preview = input.cut ? impl_->preview : nullptr;
    impl_->frame = next;
    next->timings.total_ms = elapsed(started);
    return next;
}

FramePtr PreviewHost::render_pair(const fs::path& identity, const PairInput& pair, DecodeMode mode,
                                  const RenderSettings& settings) {
    const auto started = Clock::now();
    const bool scan_film = validate_settings(settings, impl_->catalog);
    require(mode == DecodeMode::compatible16 || mode == DecodeMode::headroom, "Unknown RAW decode mode");
    const FramePtr previous = impl_->frame;
    const bool same = previous && previous->pair && impl_->pair && impl_->session && impl_->pair_identity == identity &&
                      previous->decode_mode == mode && same_piece(*impl_->pair, pair);
    auto next = std::shared_ptr<Frame>(new Frame());
    next->source = identity;
    next->decode_mode = mode;
    next->settings = settings;
    next->scan_film = scan_film;
    next->pair = true;
    next->pair_input = pair;
    PhotoInfo photo;
    PairLayout layout;
    // The piece, composed only when it is another piece; the photo's facts
    // (the second curve) may move on the same one.
    std::optional<io::DecodedRaw> composed;
    SessionPtr session{nullptr, &spk_session_release};
    OutputEncoding encoding = impl_->encoding;
    auto t = Clock::now();
    if (same) {
        layout = impl_->pair_layout;
        photo = impl_->pair_photo;
        photo.pair.latitude_b = pair.latitude_b;
        next->pair_filled = previous->pair_filled;
        next->pair_metered = previous->pair_metered;
        next->pair_metadata = previous->pair_metadata;
        next->pair_picture_w = previous->pair_picture_w;
        next->pair_picture_h = previous->pair_picture_h;
        next->metadata = previous->metadata;
    } else {
        // Each hole's picture: kept, or decoded now with the frame's own white
        // balance and cut by its own geometry. One that cannot be had is an
        // empty hole (PairComposer.decode, :30-43).
        std::array<std::shared_ptr<const PairPicture>, 2> pictures;
        std::array<std::string, 2> keys;
        for (int side = 0; side < 2; ++side) {
            const auto& hole = pair.holes[side];
            if (!hole || !fs::is_regular_file(hole->source)) continue;
            keys[side] = hole_key(*hole, mode);
            auto kept = std::find_if(impl_->holes.begin(), impl_->holes.end(),
                                     [&](const Impl::HolePicture& h) { return h.key == keys[side]; });
            if (kept == impl_->holes.end()) {
                io::DecodedRaw decoded;
                std::string error;
                if (!decode_raw(hole->source, mode, hole->decode, decoded, error)) continue;
                auto picture = std::make_shared<PairPicture>();
                if (hole->geometry.identity()) {
                    picture->width = decoded.width;
                    picture->height = decoded.height;
                    picture->rgb = std::move(decoded.rgb);
                } else {
                    picture->rgb = cut_decode(decoded, hole->geometry, picture->width, picture->height);
                }
                impl_->holes.insert(impl_->holes.begin(), {keys[side], std::move(picture), std::move(decoded.metadata)});
                if (impl_->holes.size() > 3) impl_->holes.pop_back();
                kept = impl_->holes.begin();
            } else if (kept != impl_->holes.begin()) {
                std::rotate(impl_->holes.begin(), kept, kept + 1);
                kept = impl_->holes.begin();
            }
            pictures[side] = kept->picture;
            next->pair_metadata[side] = kept->metadata;
            next->pair_filled[side] = true;
            next->pair_picture_w[side] = kept->picture->width;
            next->pair_picture_h[side] = kept->picture->height;
        }
        next->timings.decode_ms = elapsed(t);
        // Each hole exposed as the meter would expose it alone, plus its own
        // exposure: a plain gain on its picture (PairComposer.exposed).
        std::array<double, 2> gains{};
        std::array<PairPlacement, 2> placements{};
        for (int side = 0; side < 2; ++side) {
            if (!pair.holes[side]) continue;
            placements[side] = pair.holes[side]->placement;
            if (!pictures[side]) continue;
            const auto& hole = *pair.holes[side];
            double metered = 0.0;
            if (hole.meter) {
                const std::string key = keys[side] + "|" + hole.meter_method + "|" + settings.film_stock;
                const auto known = impl_->meters.find(key);
                if (known != impl_->meters.end()) metered = known->second;
                else {
                    metered = meter_picture(impl_->engine.get(), *pictures[side], hole, settings, impl_->catalog,
                                            impl_->options.output_color_space);
                    impl_->meters[key] = metered;
                }
            }
            next->pair_metered[side] = metered;
            gains[side] = metered + hole.exposure_ev;
        }
        layout = pair_layout_for({pictures[0].get(), pictures[1].get()}, placements, pair.spacing_mm, pair.turned);
        io::DecodedRaw piece;
        piece.rgb = compose_pair(layout, {pictures[0].get(), pictures[1].get()}, placements, gains);
        piece.width = layout.width();
        piece.height = layout.height();
        // The piece's EXIF is its first frame's, as on the Mac.
        piece.metadata = next->pair_filled[0] ? next->pair_metadata[0] : next->pair_metadata[1];
        next->metadata = piece.metadata;
        photo.shooting = piece.metadata.shooting;
        photo.decode_width = piece.width;
        photo.decode_height = piece.height;
        photo.pair.active = true;
        photo.pair.second = next->pair_metadata[1].shooting;
        photo.pair.split = pair_split(layout);
        photo.pair.latitude_b = pair.latitude_b;
        t = Clock::now();
        auto opened = open_session(impl_->engine.get(), piece.rgb.data(), piece.width, piece.height, settings,
                                   impl_->catalog, impl_->options.output_color_space, photo);
        session = std::move(opened.session);
        encoding = opened.encoding;
        next->timings.open_ms = elapsed(t);
        composed = std::move(piece);
    }
    spk_session* live = same ? impl_->session.get() : session.get();
    try {
        t = Clock::now();
        if (same) {
            const auto delta = changed_params(previous->settings, settings, impl_->catalog, impl_->pair_photo, photo);
            if (!delta.fields().empty()) {
                const auto text = delta.dump();
                require(spk_set_params(live, text.c_str(), nullptr) == SPK_OK,
                        "Apply settings: " + std::string(spk_last_error(impl_->engine.get())));
            }
            next->timings.params_ms = elapsed(t);
            t = Clock::now();
            require(spk_reprint(live, "full", &next->result_) == SPK_OK,
                    "Render: " + std::string(spk_last_error(impl_->engine.get())));
        } else {
            require(spk_render(live, "full", &next->result_) == SPK_OK,
                    "Render: " + std::string(spk_last_error(impl_->engine.get())));
        }
        next->timings.render_ms = elapsed(t);
        next->timings.engine_render_ms = next->result_.elapsed_ms;
        next->encoding = encoding;
        next->overscan_geometry = read_overscan_geometry(live);
        // Where the holes are on the frame: the engine's gates on a strip,
        // the layout's rectangles otherwise (Session.pairHoleRects).
        std::array<PairRect, 2> gates;
        if (std::get<bool>(settings.get("overscan_active")) && pair_gate_rects(next->overscan_geometry, pair.turned, gates))
            next->pair_holes = gates;
        else
            next->pair_holes = {layout.normalised(0), layout.normalised(1)};
        // A frame with a print of its own: the same negative printed with its
        // settings and cut into its hole, the session put back to the film's
        // print after (Session.pairLayered, Renderer.compositePair).
        bool layered = false;
        for (int side = 0; side < 2; ++side) layered = layered || (pair.holes[side] && pair.holes[side]->print && next->pair_filled[side]);
        if (layered) {
            const auto& base = next->result_;
            const std::uint32_t W = base.width, H = base.height;
            next->owned_.resize(std::size_t(W) * H * 4);
            for (std::uint32_t y = 0; y < H; ++y)
                std::copy_n(base.rgba16 + std::size_t(y) * base.row_stride_px * 4, std::size_t(W) * 4,
                            next->owned_.data() + std::size_t(y) * W * 4);
            for (int side = 0; side < 2; ++side) {
                const auto& hole = pair.holes[side];
                if (!hole || !hole->print || !next->pair_filled[side]) continue;
                const auto delta = changed_params(settings, *hole->print, impl_->catalog, photo, photo);
                if (!delta.fields().empty()) {
                    const auto text = delta.dump();
                    require(spk_set_params(live, text.c_str(), nullptr) == SPK_OK,
                            "Print a frame: " + std::string(spk_last_error(impl_->engine.get())));
                }
                spk_result own{};
                const auto status = spk_reprint(live, "full", &own);
                const auto release = [&] { spk_result_free(&own); };
                if (status != SPK_OK || own.width != W || own.height != H) {
                    release();
                    throw std::runtime_error("Print a frame: " + std::string(spk_last_error(impl_->engine.get())));
                }
                const PairRect& r = next->pair_holes[side];
                const std::uint32_t x0 = std::uint32_t(std::clamp(std::lround(r.x * W), 0L, long(W)));
                const std::uint32_t x1 = std::uint32_t(std::clamp(std::lround((r.x + r.w) * W), long(x0), long(W)));
                const std::uint32_t y0 = std::uint32_t(std::clamp(std::lround(r.y * H), 0L, long(H)));
                const std::uint32_t y1 = std::uint32_t(std::clamp(std::lround((r.y + r.h) * H), long(y0), long(H)));
                for (std::uint32_t y = y0; y < y1; ++y)
                    std::copy_n(own.rgba16 + (std::size_t(y) * own.row_stride_px + x0) * 4, std::size_t(x1 - x0) * 4,
                                next->owned_.data() + (std::size_t(y) * W + x0) * 4);
                release();
                const auto back = changed_params(*hole->print, settings, impl_->catalog, photo, photo);
                if (!back.fields().empty()) {
                    const auto text = back.dump();
                    require(spk_set_params(live, text.c_str(), nullptr) == SPK_OK,
                            "Print the film: " + std::string(spk_last_error(impl_->engine.get())));
                }
            }
            spk_result_free(&next->result_);
            next->result_ = spk_result{};
            next->result_.rgba16 = next->owned_.data();
            next->result_.width = W;
            next->result_.height = H;
            next->result_.row_stride_px = W;
            next->pair_layered = true;
        }
        if (impl_->options.bgra8_display) {
            t = Clock::now();
            next->bgra8 = rgba16_to_bgra8(next->result_);
            next->timings.display_ms = elapsed(t);
        }
    } catch (...) {
        // A session that may have taken part of a delta is never reused.
        if (same) impl_->session.reset();
        throw;
    }
    next->decode_width = photo.decode_width;
    next->decode_height = photo.decode_height;
    next->picture_width = photo.decode_width;
    next->picture_height = photo.decode_height;
    // Commit only after everything succeeded.
    if (!same) {
        impl_->session = std::move(session);
        impl_->encoding = encoding;
        impl_->decoded = std::move(*composed);
        impl_->session_cut.reset();
        impl_->preview.reset();
        impl_->pair_identity = identity;
        impl_->pair_layout = layout;
    }
    impl_->pair = pair;
    impl_->pair_photo = photo;
    impl_->frame = next;
    next->timings.total_ms = elapsed(started);
    return next;
}

void PreviewHost::export_tiff(const Frame& frame, const fs::path& destination) const {
    require(frame.encoding.is_encoded_srgb(),
            "TIFF export writes sRGB, but this frame is encoded in " + frame.encoding.color_space +
                (frame.encoding.cctf_encoding ? "" : " (linear)"));
    const auto& pixels = frame.pixels();
    std::string error;
    const bool written = io::write_srgb_tiff(destination, pixels.rgba16, pixels.width, pixels.height,
                                            pixels.row_stride_px, impl_->resources / "io" / "sRGB.icc", error);
    require(written, "TIFF export: " + error);
}

spk_engine* PreviewHost::engine() const noexcept { return impl_->engine.get(); }

FramePtr PreviewHost::render_digital_intermediate() {
    const auto started = Clock::now();
    require(bool(impl_->frame), "Open a RAW image before exporting its Digital Intermediate");
    const FramePtr& current = impl_->frame;
    if (!impl_->session) {
        // Reopened as the current frame was made: whole, or cut by its
        // geometry (Film Edge, Date Back on a cropped frame).
        EngineInput input = engine_input(current->settings, impl_->decoded, current->geometry);
        // A pair's piece is handed whole, with the pair's own facts.
        if (impl_->pair) input = {impl_->pair_photo, false};
        std::vector<float> cut_rgb;
        std::uint32_t pw = impl_->decoded.width, ph = impl_->decoded.height;
        if (input.cut) cut_rgb = cut_decode(impl_->decoded, input.photo.geometry, pw, ph);
        auto opened = open_session(impl_->engine.get(), input.cut ? cut_rgb.data() : impl_->decoded.rgb.data(), pw,
                                   ph, current->settings, impl_->catalog, impl_->options.output_color_space,
                                   input.photo);
        impl_->session = std::move(opened.session);
        impl_->encoding = opened.encoding;
        impl_->session_cut = input.cut ? std::optional<EngineCut>(input.photo.geometry) : std::nullopt;
    }
    auto next = std::shared_ptr<Frame>(new Frame());
    next->source = current->source;
    next->decode_mode = current->decode_mode;
    next->settings = current->settings;
    next->scan_film = current->scan_film;
    next->metadata = current->metadata;
    next->decode_timings = current->decode_timings;
    // The DI is the session's negative: cut as the current frame is, the film
    // around it included, so it takes no geometry of its own either.
    next->geometry = current->geometry;
    next->cut = current->cut;
    next->decode_width = current->decode_width;
    next->decode_height = current->decode_height;
    next->picture_width = current->picture_width;
    next->picture_height = current->picture_height;
    next->overscan_geometry = current->overscan_geometry;
    char* reply_text = nullptr;
    const auto t = Clock::now();
    const auto status = spk_render_digital_intermediate(impl_->session.get(), &next->result_, &reply_text);
    const std::unique_ptr<char, decltype(&spk_string_free)> reply_owner(reply_text, &spk_string_free);
    require(status == SPK_OK, "Digital Intermediate: " + std::string(spk_last_error(impl_->engine.get())));
    next->timings.render_ms = elapsed(t);
    next->timings.engine_render_ms = next->result_.elapsed_ms;
    std::string primaries = impl_->encoding.color_space;
    if (reply_text) {
        Json reply;
        std::string error;
        if (Json::parse(reply_text, reply, error) && reply.is_object() && reply.has("primaries") &&
            reply.at("primaries").is_string())
            primaries = reply.at("primaries").as_string();
    }
    next->encoding = {"Cineon log/" + primaries, true};
    next->timings.total_ms = elapsed(started);
    return next;
}

}  // namespace spk::desktop
