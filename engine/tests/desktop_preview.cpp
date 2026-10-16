// Headless tests of the desktop host boundary. The default invocation is pure
// CPU: conversion, viewport and the settings table against the engine schema.
// --settings-engine drives the table through the real engine on a synthetic
// frame; the other modes use the real engine and RAW fixtures.
#include "desktop/preview_host.hpp"
#include "desktop/viewport.hpp"
#include "core/json.hpp"
#include "core/params.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using spk::Json;
using namespace spk::desktop;

namespace {

std::uint64_t checks = 0;

void check(bool condition, const char* message) {
    ++checks;
    if (!condition) throw std::runtime_error(message);
}

template<class F> std::string rejected(F&& function, const char* message) {
    try { function(); }
    catch (const std::exception& error) {
        check(*error.what() != '\0', "rejection omitted diagnostic");
        return error.what();
    }
    throw std::runtime_error(message);
}

std::string path_text(const fs::path& path) {
    const auto utf8 = path.u8string();
    return std::string(reinterpret_cast<const char*>(utf8.data()), utf8.size());
}

// Mutation fingerprint only, not a cryptographic provenance claim. The Python
// integration runner separately records SHA-256 of binaries, inputs and TIFF.
std::uint64_t fingerprint(const void* data, std::size_t size,
                          std::uint64_t hash = 14695981039346656037ull) {
    const auto* bytes = static_cast<const std::uint8_t*>(data);
    for (std::size_t i = 0; i < size; ++i) {
        hash ^= bytes[i];
        hash *= 1099511628211ull;
    }
    return hash;
}

std::string hex(std::uint64_t value) {
    std::ostringstream text;
    text << std::hex << std::setfill('0') << std::setw(16) << value;
    return text.str();
}

std::uint64_t frame_fingerprint(const Frame& frame) {
    const auto& pixels = frame.pixels();
    std::uint64_t hash = 14695981039346656037ull;
    for (std::uint32_t y = 0; y < pixels.height; ++y)
        hash = fingerprint(pixels.rgba16 + std::size_t(y) * pixels.row_stride_px * 4,
                           std::size_t(pixels.width) * 4 * sizeof(std::uint16_t), hash);
    return hash;
}

Json json_of(const SettingValue& value) {
    return std::visit([](const auto& v) { return Json(v); }, value);
}

bool same_json(const Json& a, const Json& b) { return a.dump() == b.dump(); }

std::vector<std::string> keys_of(const Json& object) {
    std::vector<std::string> keys;
    for (const auto& kv : object.fields()) keys.push_back(kv.first);
    return keys;
}

// A catalogue shaped like the real one, small enough to reason about: two
// colour negatives that name a paper, a slide that names none, a
// black-and-white film on its silver paper, and a cine paper.
Catalog test_catalog() {
    return {{{"kodak_portra_400", "Portra 400", false, false, false, "kodak_portra_endura"},
             {"kodak_ektar_100", "Ektar 100", false, false, false, "kodak_portra_endura"},
             {"kodak_ektachrome_100", "Ektachrome 100", true},
             {"kodak_tri_x_400", "Tri-X 400", false, false, true, "ilford_multigrade_iv_rc"}},
            {{"kodak_supra_endura", "Supra Endura", false}, {"kodak_portra_endura", "Portra Endura", false},
             {"ilford_multigrade_iv_rc", "Multigrade IV RC", false, false, true},
             {"kodak_2383", "Vision 2383", false, true}}};
}

// The desktop table against the engine's own: every row is a wire field of
// the same type and layer, inside the engine's range, and `absent` -- what a
// record saved before the row existed rendered with -- is the engine default.
// A product row is no engine field at all, and an older record was made with
// its initial behaviour.
void settings_schema() {
    const auto& fields = setting_fields();
    const Json engine_defaults = spk::read_params(spk::Params{});
    std::vector<std::string> seen;
    for (const auto& field : fields) {
        check(std::find(seen.begin(), seen.end(), field.key) == seen.end(), "duplicate settings row");
        seen.push_back(field.key);
        check(find_setting(field.key) == &field, "find_setting does not return the table row");
        const auto& schema = spk::schema_fields();
        const auto row = std::find_if(schema.begin(), schema.end(),
            [&](const spk::SchemaField& f) { return field.key == f.name; });
        if (!field.wire) {
            if (row != schema.end()) throw std::runtime_error("product row shadows an engine field: " + field.key);
            check(field.initial == field.absent && check_setting(field, field.initial).empty(),
                  "a product row's defaults disagree or fail its validation");
            continue;
        }
        if (row == schema.end()) throw std::runtime_error("settings row is not an engine wire field: " + field.key);
        const auto expected = field.type == SettingType::boolean ? spk::FieldType::Bool
                            : field.type == SettingType::number ? spk::FieldType::Float : spk::FieldType::Str;
        check(row->type == expected, "settings row type differs from the engine schema");
        check((field.layer == SettingLayer::shoot) == (row->layer == spk::Layer::Shoot),
              "settings row layer differs from the engine schema");
        if (field.type == SettingType::number)
            check(row->has_range && field.low >= row->lo && field.high <= row->hi && field.low < field.high,
                  "desktop range is wider than the engine's");
        if (!same_json(json_of(field.absent), engine_defaults.at(field.key)))
            throw std::runtime_error("absent value is not the engine default: " + field.key);
        check(check_setting(field, field.initial).empty() && check_setting(field, field.absent).empty(),
              "a row's own defaults fail its validation");
        for (const auto& name : field.listed) {
            Json probe = Json::object();
            probe.set(field.key, Json(name));
            std::string error, param;
            check(spk::validate_delta(probe, error, param), "a listed choice is refused by the engine");
        }
    }
    // The complete open request, fixed I/O policy included, is one the
    // engine's schema accepts: no misspelt or retired wire name -- the
    // black-and-white pair's neutral pack included.
    std::string error, param;
    if (!spk::validate_delta(opening_params(RenderSettings{}, test_catalog()), error, param))
        throw std::runtime_error("default opening parameters fail the engine schema: " + error);
    RenderSettings silver;
    silver.film_stock = "kodak_tri_x_400";
    silver.print_stock = "ilford_multigrade_iv_rc";
    if (!spk::validate_delta(opening_params(silver, test_catalog()), error, param))
        throw std::runtime_error("black-and-white opening parameters fail the engine schema: " + error);
}

// Defaults: the engine's, except where a new photograph follows macOS.
void settings_defaults() {
    const RenderSettings settings;
    std::vector<std::string> deviations;
    for (const auto& field : setting_fields()) {
        check(settings.get(field.key) == field.initial, "default settings differ from the rows' initial values");
        if (field.initial != field.absent) deviations.push_back(field.key);
    }
    // Each with its macOS source (Params.swift): FilmParams.printStock,
    // FilmParams.filterShiftCC, FilmParams.autoExposureMethod.
    check(deviations == std::vector<std::string>{"print_stock", "filter_shift_scale", "auto_exposure_method"},
          "new-photograph defaults deviate from the engine for an undocumented row");
    check(settings.film_stock == "kodak_portra_400" && settings.print_stock == "kodak_supra_endura",
          "default film/paper pair is not the macOS one");
    check(settings.get("filter_shift_scale") == SettingValue(40.0), "filter sliders are not macOS strength");
    check(settings.get("auto_exposure_method") == SettingValue(std::string("balanced")),
          "default metering is not balanced");
    // A UI format label such as "35 mm" is no licence to substitute 36.
    check(settings.film_format_mm == 35.0, "desktop film format default differs from engine");
}

void settings_access() {
    RenderSettings settings;
    // Named members and keyed access are one value.
    settings.film_exposure_ev = 1.25;
    check(settings.get("exposure_compensation_ev") == SettingValue(1.25), "named member and wire key disagree");
    settings.set("exposure_compensation_ev", 2.5);
    check(settings.film_exposure_ev == 2.5, "keyed write missed the named member");
    settings.set("grain_active", false);
    check(!settings.grain_active, "keyed bool write missed the named member");
    settings.set("print_stock", std::string("kodak_portra_endura"));
    check(settings.print_stock == "kodak_portra_endura", "keyed text write missed the named member");
    // A row without a member still takes part in equality.
    RenderSettings other = settings;
    check(other == settings, "copied settings differ");
    other.set("filter_shift_scale", 1.0);
    check(other != settings && other.get("filter_shift_scale") == SettingValue(1.0), "keyed-only row ignored");
    other.set("filter_shift_scale", 40.0);
    check(other == settings, "restored keyed-only row still differs");
    rejected([&] { settings.set("no_such_setting", 1.0); }, "unknown setting accepted");
    rejected([&] { (void)settings.get("no_such_setting"); }, "unknown setting read");
    rejected([&] { settings.set("grain_amount", true); }, "bool accepted for a number row");
    rejected([&] { settings.set("grain_active", 1.0); }, "number accepted for a bool row");
    rejected([&] { settings.set("auto_exposure_method", 0.5); }, "number accepted for a text row");
    check(settings.grain_amount == 1.0 && !settings.grain_active, "rejected write changed a value");
}

void settings_validation() {
    const auto catalog = test_catalog();
    RenderSettings settings;
    check(!validate_settings(settings, catalog), "default negative film reported as scanned");
    settings.set("scan_film", true);
    check(validate_settings(settings, catalog), "No Print Profile did not scan a negative");
    settings.set("scan_film", false);
    settings.film_stock = "kodak_ektachrome_100";
    check(validate_settings(settings, catalog), "slide film not reported as scanned");
    for (const auto& field : setting_fields()) {
        if (field.type == SettingType::number) {
            for (double value : {field.low, field.high}) {
                RenderSettings edge;
                edge.set(field.key, value);
                validate_settings(edge, catalog);
                ++checks;
            }
            const double span = field.high - field.low;
            for (double value : {field.low - span * 1e-3, field.high + span * 1e-3,
                                 std::numeric_limits<double>::quiet_NaN(),
                                 std::numeric_limits<double>::infinity(),
                                 -std::numeric_limits<double>::infinity()}) {
                RenderSettings invalid;
                invalid.set(field.key, value);
                const auto error = rejected([&] { validate_settings(invalid, catalog); },
                                            "out-of-range setting accepted");
                check(error.find(field.label) != std::string::npos, "range error does not name the setting");
                check(!check_setting(field, SettingValue(value)).empty(), "check_setting accepted a bad number");
            }
        } else if (field.type == SettingType::text) {
            RenderSettings invalid;
            invalid.set(field.key, std::string("__not_a_choice__"));
            rejected([&] { validate_settings(invalid, catalog); }, "unknown text choice accepted");
        }
        check(!check_setting(field, SettingValue(std::string("1"))).empty() || field.type == SettingType::text,
              "text accepted for a non-text row");
    }
    // Without a catalogue only the shape of a stock can be judged.
    const auto* film = find_setting("film_stock");
    check(check_setting(*film, SettingValue(std::string("kodak_vision3_500t"))).empty(),
          "stock rejected without a catalogue");
    check(!check_setting(*film, SettingValue(std::string("kodak_vision3_500t")), &catalog).empty(),
          "stock outside the catalogue accepted");
}

// The catalogue's rules, as macOS states them (StockCatalog.swift, Session
// .swift selectFilmStock), on the test catalogue.
void catalogue_rules() {
    const auto catalog = test_catalog();
    check(catalog.film("kodak_tri_x_400") && catalog.film("kodak_tri_x_400")->is_monochrome &&
          !catalog.film("kodak_supra_endura") && catalog.paper("kodak_supra_endura") && !catalog.paper("nope"),
          "catalogue lookup");
    // Silver on silver, colour on colour; an unknown stock rules nothing out.
    check(can_print(catalog, "kodak_tri_x_400", "ilford_multigrade_iv_rc") &&
          !can_print(catalog, "kodak_tri_x_400", "kodak_supra_endura") &&
          !can_print(catalog, "kodak_portra_400", "ilford_multigrade_iv_rc") &&
          can_print(catalog, "kodak_portra_400", "kodak_2383") &&
          can_print(catalog, "kodak_ektachrome_100", "kodak_supra_endura") &&
          can_print(catalog, "unknown_film", "ilford_multigrade_iv_rc") &&
          can_print(catalog, "kodak_tri_x_400", "unknown_paper"), "canPrint pairing rule");
    // The film's own paper whenever it names one; a slide keeps the paper;
    // across colour and black and white the paper cannot stay.
    const std::string fallback = "kodak_supra_endura";
    check(paper_for_film(catalog, "kodak_ektar_100", "kodak_supra_endura", fallback) == "kodak_portra_endura",
          "a film did not take its own paper");
    check(paper_for_film(catalog, "kodak_portra_400", "kodak_portra_endura", fallback) == "kodak_portra_endura",
          "a film's own paper moved");
    check(paper_for_film(catalog, "kodak_ektachrome_100", "kodak_2383", fallback) == "kodak_2383",
          "a slide did not keep the paper for the next negative");
    check(paper_for_film(catalog, "kodak_tri_x_400", "kodak_supra_endura", fallback) == "ilford_multigrade_iv_rc",
          "a black-and-white film kept a colour paper");
    check(paper_for_film(catalog, "kodak_portra_400", "ilford_multigrade_iv_rc", fallback) == "kodak_portra_endura",
          "a colour film kept the silver paper");
    check(paper_for_film(catalog, "kodak_ektachrome_100", "ilford_multigrade_iv_rc", fallback) == fallback,
          "a slide on the silver paper did not fall back to the default paper");
    // Groups in macOS order: positives, negatives, then black and white;
    // papers still then cine.
    const auto names = [](const StockGroup& group) {
        std::vector<std::string> ids;
        for (const Stock* s : group.stocks) ids.push_back(s->id);
        return ids;
    };
    const auto films = film_groups(catalog);
    check(films.size() == 3 && films[0].key == "positive" && films[1].key == "negative" &&
          films[2].key == "blackAndWhite", "film group keys or order");
    check(names(films[0]) == std::vector<std::string>{"kodak_ektachrome_100"} &&
          names(films[1]) == std::vector<std::string>{"kodak_ektar_100", "kodak_portra_400"} &&
          names(films[2]) == std::vector<std::string>{"kodak_tri_x_400"}, "film groups' members or order");
    Catalog colour = catalog;
    colour.films.pop_back();
    check(film_groups(colour).size() == 2, "a catalogue without black and white drew an empty group");
    const auto papers = paper_groups(catalog);
    check(papers.size() == 2 && papers[0].key == "still" && papers[1].key == "cine" &&
          names(papers[0]) == std::vector<std::string>{"ilford_multigrade_iv_rc", "kodak_portra_endura",
                                                       "kodak_supra_endura"} &&
          names(papers[1]) == std::vector<std::string>{"kodak_2383"}, "paper groups");
    check(own_grain("kodak_tri_x_400") == 1.70 && own_grain("ilford_hp5_plus_400") == 1.49 &&
          own_grain("kodak_tmax_100") == 0.74 && own_grain("fujifilm_neopan_acros_100_ii") == 0.64 &&
          own_grain("kodak_portra_400") == 1.0, "own grain differs from macOS FilmParams.ownGrain");
}

// What the settings put on the wire (wire_params), rule by rule.
void wire_rules() {
    const auto catalog = test_catalog();
    const RenderSettings base;
    const Json plain = wire_params(base, catalog);
    // A colour negative: every wire row as it is, no product row, no pack.
    std::size_t wire_rows = 0;
    for (const auto& field : setting_fields()) {
        if (!field.wire) {
            check(!plain.has(field.key), "a product row was sent");
            continue;
        }
        ++wire_rows;
        check(same_json(plain.at(field.key), json_of(base.get(field.key))), "a colour negative's row was rewritten");
    }
    check(plain.fields().size() == wire_rows, "a colour pair carries extra fields");
    // A slide is scanned whatever the row says; No Print Profile scans a negative.
    RenderSettings slide = base;
    slide.film_stock = "kodak_ektachrome_100";
    check(wire_params(slide, catalog).at("scan_film").as_bool(), "a slide film is printed");
    RenderSettings scanned = base;
    scanned.set("scan_film", true);
    check(wire_params(scanned, catalog).at("scan_film").as_bool(), "No Print Profile did not scan");
    // Print Effects gates glare and pre-flash and forgets neither.
    RenderSettings effects = base;
    effects.set("preflash_exposure", 0.02);
    check(wire_params(effects, catalog).at("preflash_exposure").as_double() == 0.02 &&
          wire_params(effects, catalog).at("glare_active").as_bool(), "pre-flash or glare not sent");
    effects.set("print_effects", false);
    const Json gated = wire_params(effects, catalog);
    check(!gated.at("glare_active").as_bool() && gated.at("preflash_exposure").as_double() == 0.0,
          "Print Effects off still sends glare or pre-flash");
    check(effects.glare_active && effects.get("preflash_exposure") == SettingValue(0.02),
          "Print Effects off forgot glare or pre-flash");
    // ...and the Tone Mask (Params.swift:763), whose settings it keeps too.
    RenderSettings masked = base;
    masked.set("contrast_mask_active", true);
    check(wire_params(masked, catalog).at("contrast_mask_active").as_bool(), "the tone mask is not sent");
    masked.set("print_effects", false);
    check(!wire_params(masked, catalog).at("contrast_mask_active").as_bool() &&
          std::get<bool>(masked.get("contrast_mask_active")), "Print Effects off sent the tone mask, or forgot it");
    // Black and white: one grain layer, the film's own grain, and on the
    // silver paper Multigrade filter 2 as the neutral pack.
    RenderSettings silver = base;
    silver.film_stock = "kodak_tri_x_400";
    silver.print_stock = "ilford_multigrade_iv_rc";
    const Json bw = wire_params(silver, catalog);
    check(!bw.at("grain_sublayers_active").as_bool() && std::get<bool>(silver.get("grain_sublayers_active")),
          "grain sub-layers sent on a black-and-white film");
    check(std::abs(bw.at("grain_amount").as_double() - 1.70) < 1e-12, "black-and-white grain is not the film's own");
    check(bw.at("c_filter_neutral").as_double() == 0.0 && bw.at("m_filter_neutral").as_double() == 0.0 &&
          bw.at("y_filter_neutral").as_double() == 68.0 && bw.fields().size() == wire_rows + 3,
          "silver pair lacks Multigrade filter 2");
    silver.grain_amount = 1.5;  // x1.70 is past the wire's 2
    check(wire_params(silver, catalog).at("grain_amount").as_double() == 2.0, "grain amount escaped its range");
    // The pack only on the silver paper: a black-and-white film anywhere else
    // (which the controller refuses) or a colour film carries none.
    silver.print_stock = "kodak_supra_endura";
    check(!wire_params(silver, catalog).has("m_filter_neutral"), "silver pack sent for a colour paper");
    // A stock the catalogue does not know is a colour negative.
    RenderSettings unknown = base;
    unknown.film_stock = "kodak_vision3_500t";
    check(!wire_params(unknown, catalog).at("scan_film").as_bool(), "an unknown film was scanned");
}

void settings_deltas() {
    const auto catalog = test_catalog();
    const RenderSettings base;
    // Opening sends the host's I/O policy and wire_params: every wire row.
    const auto open = opening_params(base, catalog);
    std::size_t wire_rows = 0;
    for (const auto& field : setting_fields()) {
        if (!field.wire) continue;
        ++wire_rows;
        check(same_json(open.at(field.key), json_of(base.get(field.key))), "opening parameters omit or alter a row");
    }
    check(!open.at("scan_film").as_bool() && open.at("output_color_space").as_string() == "sRGB" &&
          open.at("input_color_space").as_string() == "ProPhoto RGB" && !open.at("extended_dynamic_range").as_bool(),
          "opening parameters lost the host's fixed policy");
    check(open.fields().size() == wire_rows + 5, "opening parameters carry an unexpected field");
    RenderSettings slide_open = base;
    slide_open.film_stock = "kodak_ektachrome_100";
    check(opening_params(slide_open, catalog).at("scan_film").as_bool(), "a slide opened printed");
    // The request is the host's option; it is not what a frame is tagged
    // with (output_encoding reads the reply, below and in --settings-engine).
    check(opening_params(base, catalog, "ProPhoto RGB").at("output_color_space").as_string() == "ProPhoto RGB" &&
          opening_params(base, catalog, "ProPhoto RGB").at("output_cctf_encoding").as_bool(),
          "requested output colour space not passed through");

    // The open reply's resolved encoding, and refusals for a reply that does
    // not say: a frame must never be tagged from a default.
    const auto reply = [](const char* text) {
        Json value;
        std::string error;
        if (!Json::parse(text, value, error)) throw std::runtime_error("test reply: " + error);
        return value;
    };
    check(output_encoding(reply(R"({"params":{"output_color_space":"ProPhoto RGB","output_cctf_encoding":true}})")) ==
              OutputEncoding{"ProPhoto RGB", true}, "resolved encoding not read from the reply");
    check(output_encoding(reply(R"({"params":{"output_color_space":"sRGB","output_cctf_encoding":false}})")) ==
              OutputEncoding{"sRGB", false}, "linear output not read from the reply");
    check(OutputEncoding{"sRGB", true}.is_encoded_srgb() && !OutputEncoding{"sRGB", false}.is_encoded_srgb() &&
          !OutputEncoding{"Display P3", true}.is_encoded_srgb(), "encoded-sRGB test is wrong");
    for (const char* bad : {R"({})", R"({"params":{}})", R"({"params":[]})",
                            R"({"params":{"output_cctf_encoding":true}})",
                            R"({"params":{"output_color_space":"","output_cctf_encoding":true}})",
                            R"({"params":{"output_color_space":3,"output_cctf_encoding":true}})",
                            R"({"params":{"output_color_space":"sRGB"}})",
                            R"({"params":{"output_color_space":"sRGB","output_cctf_encoding":1}})",
                            R"({"output_color_space":"sRGB","output_cctf_encoding":true})"})
        rejected([&] { output_encoding(reply(bad)); }, "open reply without a resolved encoding accepted");

    check(changed_params(base, base, catalog).fields().empty(), "unchanged settings produced a delta");
    // Each wire row alone produces exactly its own key; a film change also
    // carries the resolved scan mode. A product row produces the wire values
    // it changes: Print Effects off turns glare off (pre-flash is at 0, the
    // Tone Mask is off); the white balance and the placement's UI state
    // change none -- the white balance is the decode (render re-opens).
    for (const auto& field : setting_fields()) {
        RenderSettings after = base;
        SettingValue value;
        switch (field.type) {
        case SettingType::boolean: value = !std::get<bool>(base.get(field.key)); break;
        case SettingType::number: value = std::get<double>(base.get(field.key)) == field.high ? field.low : field.high; break;
        case SettingType::text:
            value = field.key == "film_stock" ? std::string("kodak_ektar_100")
                  : field.key == "print_stock" ? std::string("kodak_portra_endura") : field.listed.back();
            break;
        }
        after.set(field.key, value);
        const auto delta = changed_params(base, after, catalog);
        if (after == base) {  // a one-choice row (contrast_mask_scheme) cannot change
            check(delta.fields().empty(), "an unchanged row produced a delta");
            continue;
        }
        std::vector<std::string> expected;
        if (field.wire) expected.push_back(field.key);
        else if (field.key == "print_effects") expected.push_back("glare_active");
        if (field.key == "film_stock") expected.push_back("scan_film");
        std::sort(expected.begin(), expected.end());
        if (keys_of(delta) != expected) throw std::runtime_error("delta is not minimal for " + field.key);
        if (field.wire) check(same_json(delta.at(field.key), json_of(value)), "delta carries the wrong value");
        if (field.key == "film_stock") check(!delta.at("scan_film").as_bool(), "film delta lost scan mode");
    }
    // A paper-only edit never touches the film side, whose cached grain
    // realisation it would otherwise invalidate.
    RenderSettings print = base;
    print.print_exposure = 0.8;
    print.y_filter_shift = 0.25;
    print.set("filter_shift_scale", 1.0);
    print.set("preflash_exposure", 0.01);
    print.print_stock = "kodak_portra_endura";
    const auto print_delta = changed_params(base, print, catalog);
    check(keys_of(print_delta) == std::vector<std::string>{"filter_shift_scale", "preflash_exposure", "print_exposure",
                                                             "print_stock", "y_filter_shift"},
          "paper edit delta is not minimal");
    for (const auto& key : keys_of(print_delta))
        check(find_setting(key)->layer == SettingLayer::print, "paper edit delta touched the film side");
    // Print Effects off then on: the gated values leave the wire and return.
    RenderSettings plain = print;
    plain.set("print_effects", false);
    const auto gate = changed_params(print, plain, catalog);
    check(keys_of(gate) == std::vector<std::string>{"glare_active", "preflash_exposure"} &&
          !gate.at("glare_active").as_bool() && gate.at("preflash_exposure").as_double() == 0.0,
          "Print Effects off delta");
    const auto ungate = changed_params(plain, print, catalog);
    check(keys_of(ungate) == keys_of(gate) && ungate.at("preflash_exposure").as_double() == 0.01,
          "Print Effects on did not restore pre-flash");
    // Slide and back: the scan mode follows every film change, and the
    // remembered paper rides along only when it changed.
    RenderSettings slide = print;
    slide.film_stock = "kodak_ektachrome_100";
    const auto to_slide = changed_params(print, slide, catalog);
    check(keys_of(to_slide) == std::vector<std::string>{"film_stock", "scan_film"} &&
          to_slide.at("scan_film").as_bool(), "slide change delta");
    RenderSettings negative = slide;
    negative.film_stock = "kodak_portra_400";
    negative.set("auto_exposure_method", std::string("center_weighted"));
    const auto back = changed_params(slide, negative, catalog);
    check(keys_of(back) == std::vector<std::string>{"auto_exposure_method", "film_stock", "scan_film"} &&
          !back.at("scan_film").as_bool(), "negative return delta");
    // Into black and white: the derived values ride with the stocks; out of
    // it, they return and the pack is left to the engine's own table.
    RenderSettings silver = base;
    silver.film_stock = "kodak_tri_x_400";
    silver.print_stock = "ilford_multigrade_iv_rc";
    const auto to_silver = changed_params(base, silver, catalog);
    check(keys_of(to_silver) == std::vector<std::string>{"c_filter_neutral", "film_stock", "grain_amount",
                                                           "grain_sublayers_active", "m_filter_neutral", "print_stock",
                                                           "scan_film", "y_filter_neutral"},
          "black-and-white change delta");
    const auto from_silver = changed_params(silver, base, catalog);
    check(keys_of(from_silver) == std::vector<std::string>{"film_stock", "grain_amount", "grain_sublayers_active",
                                                             "print_stock", "scan_film"} &&
          from_silver.at("grain_amount").as_double() == 1.0 && from_silver.at("grain_sublayers_active").as_bool(),
          "colour return delta");
}

void conversion() {
    // Padding deliberately contains invalid alpha: only active pixels count.
    std::array<std::uint16_t, 40> source{};
    const std::array<std::array<std::uint16_t, 4>, 6> pixels{{
        {{65535, 0, 0, 65535}}, {{0, 65535, 0, 65535}}, {{0, 0, 65535, 65535}},
        {{65535, 65535, 65535, 65535}}, {{0, 0, 0, 65535}}, {{32768, 32768, 32768, 65535}}
    }};
    for (std::size_t i = 0; i < pixels.size(); ++i)
        std::copy(pixels[i].begin(), pixels[i].end(), source.begin() + (i / 3 * 5 + i % 3) * 4);
    spk_result image{};
    image.rgba16 = source.data(); image.width = 3; image.height = 2; image.row_stride_px = 5;
    const auto display = rgba16_to_bgra8(image);
    const std::vector<std::uint8_t> expected{
        0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255,
        255, 255, 255, 255, 0, 0, 0, 255, 128, 128, 128, 255};
    check(display == expected, "BGRA channel order, top-down rows or padded pitch differ");
    std::fill(source.begin(), source.end(), 99);
    check(display == expected, "display copy aliases caller-owned RGBA16");

    std::vector<std::uint16_t> ramp(65536 * 4);
    for (std::uint32_t value = 0; value < 65536; ++value) {
        ramp[value * 4] = static_cast<std::uint16_t>(value);
        ramp[value * 4 + 1] = static_cast<std::uint16_t>(65535 - value);
        ramp[value * 4 + 2] = static_cast<std::uint16_t>((value * 17) & 65535);
        ramp[value * 4 + 3] = 65535;
    }
    image.rgba16 = ramp.data(); image.width = 65536; image.height = 1; image.row_stride_px = 65536;
    const auto quantized = rgba16_to_bgra8(image);
    for (std::uint32_t value = 0; value < 65536; ++value) {
        for (unsigned channel = 0; channel < 3; ++channel) {
            const auto rounded = std::lround(double(ramp[value * 4 + 2 - channel]) * 255.0 / 65535.0);
            check(quantized[value * 4 + channel] == rounded, "16-to-8 nearest quantization differs");
        }
        check(quantized[value * 4 + 3] == 255, "display alpha is not opaque");
    }
    for (unsigned variant = 0; variant < 7; ++variant) {
        const std::uint16_t opaque[4]{0, 0, 0, 65535};
        const std::uint16_t translucent[4]{0, 0, 0, 65534};
        spk_result invalid{};
        invalid.rgba16 = opaque; invalid.width = invalid.height = invalid.row_stride_px = 1;
        switch (variant) {
        case 0: invalid.rgba16 = nullptr; break;
        case 1: invalid.width = 0; break;
        case 2: invalid.height = 0; break;
        case 3: invalid.row_stride_px = 0; break;
        case 4: invalid.rgba16 = translucent; break;
        case 5: invalid.width = invalid.height = invalid.row_stride_px = std::numeric_limits<std::uint32_t>::max(); break;
        case 6: invalid.height = invalid.row_stride_px = std::numeric_limits<std::uint32_t>::max(); break;
        }
        rejected([&] { rgba16_to_bgra8(invalid); }, "invalid BGRA conversion accepted");
    }
}

void viewport_geometry() {
    const auto portrait = viewport(4000, 6000, 1200, 800, true);
    check(portrait.width == 533 && portrait.height == 800 && portrait.x == 333 && portrait.y == 0 &&
          std::abs(portrait.scale - 800.0 / 6000.0) < 1e-12, "portrait fit geometry");
    const auto landscape = viewport(6000, 3000, 1200, 800, true);
    check(landscape.width == 1200 && landscape.height == 600 && landscape.x == 0 && landscape.y == 100 &&
          std::abs(landscape.scale - 0.2) < 1e-12, "landscape fit geometry");
    const auto fitted_pan = viewport(6000, 3000, 1200, 800, true, 1e300, -1e300);
    check(fitted_pan.x == landscape.x && fitted_pan.y == landscape.y, "fit mode retained stale pan");
    const auto actual = viewport(6000, 4000, 1200, 800, false);
    check(actual.width == 6000 && actual.height == 4000 && actual.x == -2400 && actual.y == -1600 &&
          actual.scale == 1, "100 percent is not one image pixel per physical canvas pixel");
    const auto small = viewport(400, 200, 1200, 800, false, 1e300, -1e300);
    check(small.width == 400 && small.height == 200 && small.x == 400 && small.y == 300 && small.scale == 1,
          "small 100-percent image moved or scaled");
    const auto bottom_right = viewport(6000, 4000, 1200, 800, false, 1e300, -1e300);
    check(bottom_right.x == 0 && bottom_right.y == -3200, "extreme positive/negative pan overflowed before clamping");
    const auto top_left = viewport(6000, 4000, 1200, 800, false, -1e300, 1e300);
    check(top_left.x == -4800 && top_left.y == 0, "extreme negative/positive pan overflowed before clamping");
    const auto fractional = viewport(6000, 4000, 1200, 800, false, 23.25, -31.25);
    check(fractional.x == -2377 && fractional.y == -1631, "fractional pan rounding");
    for (const auto shape : {std::array<int, 4>{0, 100, 200, 300}, {100, 0, 200, 300},
                             {100, 100, 0, 300}, {100, 100, 200, 0}, {-1, 100, 200, 300}}) {
        const auto empty = viewport(shape[0], shape[1], shape[2], shape[3], true);
        check(empty.x == 0 && empty.y == 0 && empty.width == 0 && empty.height == 0,
              "empty viewport produced drawable geometry");
    }
}

class TiffReader {
public:
    explicit TiffReader(const fs::path& path) : stream(path, std::ios::binary | std::ios::ate) {
        check(bool(stream), "cannot read exported TIFF");
        const auto size = stream.tellg();
        check(size >= 8, "TIFF too short");
        length = std::uint64_t(size);
    }
    std::vector<std::uint8_t> read(std::uint64_t at, std::size_t count) {
        check(at <= length && count <= length - at, "TIFF field outside file");
        std::vector<std::uint8_t> bytes(count);
        stream.seekg(std::streamoff(at));
        check(bool(stream.read(reinterpret_cast<char*>(bytes.data()), std::streamsize(count))), "TIFF read incomplete");
        return bytes;
    }
    std::uint64_t length = 0;
private:
    std::ifstream stream;
};

std::uint16_t little16(const std::vector<std::uint8_t>& bytes, std::size_t at) {
    check(at <= bytes.size() && bytes.size() - at >= 2, "TIFF short outside field");
    return std::uint16_t(bytes[at]) | std::uint16_t(bytes[at + 1]) << 8;
}
std::uint32_t little32(const std::vector<std::uint8_t>& bytes, std::size_t at) {
    return std::uint32_t(little16(bytes, at)) | std::uint32_t(little16(bytes, at + 2)) << 16;
}

void compare_tiff(const fs::path& path, const Frame& frame, const fs::path& profile_path) {
    TiffReader file(path);
    const auto header = file.read(0, 8);
    check(header[0] == 'I' && header[1] == 'I' && little16(header, 2) == 42, "not classic little-endian TIFF");
    const auto ifd_at = little32(header, 4);
    const auto tags_count = little16(file.read(ifd_at, 2), 0);
    const auto ifd = file.read(ifd_at + 2, std::size_t(tags_count) * 12 + 4);
    struct Tag { std::uint16_t type; std::uint32_t count; std::vector<std::uint8_t> bytes; };
    std::map<std::uint16_t, Tag> tags;
    for (unsigned i = 0; i < tags_count; ++i) {
        const auto at = std::size_t(i) * 12;
        const auto key = little16(ifd, at), type = little16(ifd, at + 2);
        const auto count = little32(ifd, at + 4);
        const std::size_t unit = type == 3 ? 2 : type == 4 ? 4 : type == 5 ? 8 : (type == 2 || type == 7) ? 1 : 0;
        check(unit != 0 && count <= 4 * 1024 * 1024 / unit, "unexpected TIFF field size/type");
        const auto extent = count * unit;
        const auto payload = extent <= 4 ? file.read(ifd_at + 2 + at + 8, extent)
                                         : file.read(little32(ifd, at + 8), extent);
        check(tags.emplace(key, Tag{type, count, payload}).second, "duplicate TIFF field");
    }
    check(little32(ifd, std::size_t(tags_count) * 12) == 0, "unexpected second TIFF image");
    const auto number = [&](std::uint16_t key, std::uint32_t index = 0) {
        const auto& tag = tags.at(key);
        check(index < tag.count, "TIFF field index out of range");
        if (tag.type == 3) return std::uint32_t(little16(tag.bytes, index * 2));
        check(tag.type == 4, "TIFF field is not an integer");
        return little32(tag.bytes, index * 4);
    };
    const auto& pixels = frame.pixels();
    check(number(256) == pixels.width && number(257) == pixels.height, "export dimensions differ from held frame");
    check(number(259) == 1 && number(262) == 2 && number(274) == 1 && number(277) == 3 && number(284) == 1,
          "TIFF compression/colour/orientation/channel layout invalid");
    for (unsigned c = 0; c < 3; ++c)
        check(number(258, c) == 16 && number(339, c) == 1, "export is not unsigned RGB16");
    const auto rows_per_strip = number(278);
    check(rows_per_strip > 0 && rows_per_strip <= 64, "unexpected TIFF strip height");
    const auto strip_count = (pixels.height - 1) / rows_per_strip + 1;
    check(tags.at(273).count == strip_count && tags.at(279).count == strip_count, "invalid TIFF strip tables");
    std::uint64_t previous_end = 0;
    for (std::uint32_t i = 0; i < strip_count; ++i) {
        const auto first_row = i * rows_per_strip;
        const auto rows = std::min(rows_per_strip, pixels.height - first_row);
        const auto offset = number(273, i), bytes = number(279, i);
        check(bytes == std::uint64_t(rows) * pixels.width * 6 && offset >= previous_end,
              "TIFF strip size/overlap invalid");
        const auto data = file.read(offset, bytes);
        for (std::uint32_t row = 0; row < rows; ++row) {
            const auto* expected = pixels.rgba16 + (std::size_t(first_row + row) * pixels.row_stride_px) * 4;
            const auto* actual = data.data() + std::size_t(row) * pixels.width * 6;
            for (std::uint32_t x = 0; x < pixels.width; ++x)
                for (unsigned c = 0; c < 3; ++c) {
                    const auto value = std::uint16_t(actual[x * 6 + c * 2]) |
                                       std::uint16_t(actual[x * 6 + c * 2 + 1]) << 8;
                    if (value != expected[x * 4 + c]) throw std::runtime_error("TIFF pixels differ from supplied held frame");
                }
        }
        previous_end = std::uint64_t(offset) + bytes;
    }
    check(previous_end == file.length, "TIFF pixel extent does not end at file end");
    TiffReader icc(profile_path);
    const auto& embedded = tags.at(34675);
    check(embedded.type == 7 && embedded.bytes == icc.read(0, std::size_t(icc.length)), "export changed pinned sRGB ICC");
}

Json frame_report(const Frame& frame) {
    Json entry = Json::object();
    entry.set("width", Json(double(frame.width()))); entry.set("height", Json(double(frame.height())));
    entry.set("film", Json(frame.settings.film_stock)); entry.set("paper", Json(frame.settings.print_stock));
    entry.set("print_exposure", Json(frame.settings.print_exposure));
    entry.set("scan_film", Json(frame.scan_film));
    entry.set("reprint", Json(frame.reprint())); entry.set("negative_was_cached", Json(frame.negative_was_cached()));
    entry.set("headroom", Json(frame.metadata.headroom_enabled));
    Json timings = Json::object();
    timings.set("decode_ms", Json(frame.timings.decode_ms)); timings.set("open_ms", Json(frame.timings.open_ms));
    timings.set("params_ms", Json(frame.timings.params_ms)); timings.set("render_ms", Json(frame.timings.render_ms));
    timings.set("engine_render_ms", Json(frame.timings.engine_render_ms));
    timings.set("display_ms", Json(frame.timings.display_ms)); timings.set("total_ms", Json(frame.timings.total_ms));
    entry.set("timings", std::move(timings));
    return entry;
}

void edit_controls(const fs::path& resources, const fs::path& raw, const fs::path& destination) {
    check(fs::create_directory(destination), "edit control destination must be a new directory");
    PreviewHost host(resources);
    RenderSettings settings;
    // Deterministic film and print make the cache comparisons about the
    // requested edit, never a comparison of two independent random fields.
    settings.grain_active = false;
    settings.glare_active = false;
    auto current = host.open_raw(raw, DecodeMode::compatible16, settings);
    const auto held = current;
    const auto held_pixels = frame_fingerprint(*held);
    Json report = Json::object(), renders = Json::array();
    struct Range { double RenderSettings::*field; double lo, hi; };
    const std::array<Range, 8> ranges{{
        {&RenderSettings::print_exposure, 0.05, 20},
        {&RenderSettings::film_exposure_ev, -8, 8},
        {&RenderSettings::film_format_mm, 4, 200},
        {&RenderSettings::grain_amount, 0, 2},
        {&RenderSettings::halation_amount, 0, 4},
        {&RenderSettings::glare_amount, 0, 30},
        {&RenderSettings::y_filter_shift, -1, 1},
        {&RenderSettings::m_filter_shift, -1, 1}
    }};
    for (const auto& range : ranges) {
        for (double value : {range.lo - 0.01, range.hi + 0.01,
                             std::numeric_limits<double>::quiet_NaN(),
                             std::numeric_limits<double>::infinity()}) {
            auto invalid = settings;
            invalid.*(range.field) = value;
            rejected([&] { host.render(invalid); }, "invalid desktop edit value accepted");
            check(host.current() == held, "invalid desktop edit replaced the held frame");
        }
    }
    const auto edit = [&](const char* label, bool expect_cache, bool expect_difference) {
        const auto before = frame_fingerprint(*current);
        auto next = host.render(settings);
        check(next->settings == settings, "published frame lost requested edit settings");
        check(next->reprint() == expect_cache && next->negative_was_cached() == expect_cache,
              "desktop edit used the wrong film-cache path");
        if (expect_difference)
            check(frame_fingerprint(*next) != before, "desktop edit did not change rendered pixels");
        auto entry = frame_report(*next);
        entry.set("edit", Json(std::string(label)));
        renders.push(std::move(entry));
        current = std::move(next);
    };
    settings.film_exposure_ev = 1.75;
    edit("film exposure", false, true);
    settings.film_format_mm = 70;
    edit("film format", false, true);
    settings.halation_amount = 3.0;
    edit("halation amount", false, true);
    settings.halation_active = false;
    edit("halation off", false, true);
    settings.grain_amount = 0.7;
    edit("remember grain amount while disabled", false, false);
    const auto no_grain = frame_fingerprint(*current);
    settings.grain_active = true;
    edit("grain on", false, false);
    settings.print_exposure = 0.8;
    edit("paper exposure with same cached film realization", true, true);
    const auto cached_grain = frame_fingerprint(*current);
    edit("unchanged settings retain grain realization", true, false);
    check(frame_fingerprint(*current) == cached_grain, "unchanged settings regenerated the film grain");
    settings.print_exposure = 1.0;
    settings.grain_active = false;
    edit("grain off", false, false);
    check(frame_fingerprint(*current) == no_grain, "grain on/off failed to restore deterministic film output");
    settings.y_filter_shift = 0.25;
    edit("yellow enlarger filter", true, true);
    settings.m_filter_shift = -0.2;
    edit("magenta enlarger filter", true, true);
    const auto no_glare = frame_fingerprint(*current);
    settings.glare_amount = 20;
    edit("remember glare amount while disabled", true, false);
    check(frame_fingerprint(*current) == no_glare, "disabled glare amount changed pixels");
    settings.glare_active = true;
    edit("glare on", true, false);
    settings.glare_active = false;
    edit("glare off", true, false);
    check(frame_fingerprint(*current) == no_glare, "glare on/off changed the cached film");
    settings.print_stock = "fujifilm_crystal_archive_typeii";
    edit("paper stock", true, true);
    settings.halation_active = true;
    edit("halation restored before stock switch", false, true);
    settings.film_stock = "kodak_ektar_100";
    edit("film stock preserving all edits", false, true);
    const auto switched = frame_fingerprint(*current);
    current = host.open_raw(raw, DecodeMode::compatible16, settings);
    check(frame_fingerprint(*current) == switched,
          "stock switch settings differ from a fresh session with the same edits");
    check(frame_fingerprint(*held) == held_pixels, "desktop edits mutated previously held pixels");
    report.set("status", Json(std::string("passed")));
    report.set("checks", Json(double(checks)));
    report.set("raw", Json(path_text(raw)));
    report.set("renders", std::move(renders));
    report.set("pixel_comparison", Json(std::string("Deterministic grain/glare-off comparisons; unchanged cached grain compared to the same realization. No independently stochastic render equality is assumed.")));
    std::ofstream stream(destination / "edit-controls.json", std::ios::binary);
    check(bool(stream << report.dump() << '\n') && bool(stream.flush()), "cannot write edit controls report");
}

void film_policy(const fs::path& resources, const fs::path& raw, const fs::path& destination) {
    check(fs::create_directory(destination), "film policy destination must be a new directory");
    // These are the four stocks from the reported regression. Product policy
    // must use profile metadata, not this list; the list holds that coverage.
    const std::array<std::string, 4> slides{
        "fujifilm_provia_100f", "fujifilm_velvia_100", "kodak_ektachrome_100", "kodak_kodachrome_64"};
    Json report = Json::object(), renders = Json::array();
    FramePtr held;
    std::uint64_t held_pixels = 0, held_display = 0;
    const auto exported = destination / "held-slide.tif";
    {
        PreviewHost host(resources);
        for (const auto& id : slides) {
            const auto& films = host.catalog().films;
            const auto stock = std::find_if(films.begin(), films.end(),
                [&](const Stock& entry) { return entry.id == id; });
            check(stock != films.end() && stock->is_positive, "reported slide lacks positive catalog metadata");
        }
        RenderSettings settings;
        settings.film_stock = slides.front();
        auto current = host.open_raw(raw, DecodeMode::compatible16, settings);
        check(current->scan_film, "opening a slide did not select direct scan");
        check(!current->reprint() && !current->negative_was_cached(), "positive open claimed a cached render");
        for (const auto& id : slides) {
            if (settings.film_stock != id) {
                settings.film_stock = id;
                current = host.render(settings);
                check(!current->reprint() && !current->negative_was_cached(), "slide change reused another film negative");
            }
            check(current->settings.film_stock == id, "displayed slide stock differs from selection");
            check(current->scan_film, "slide transition did not select direct scan");
            const auto pixels_before = frame_fingerprint(*current);
            const auto display_before = fingerprint(current->bgra8.data(), current->bgra8.size());
            // Same cached film realisation, different paper controls: a slide
            // is scanned directly, so these must be pixel-identical even
            // though grain remains on. No unrelated random images compared.
            settings.print_exposure = settings.print_exposure == 1.0 ? 0.65 : 1.0;
            settings.print_stock = settings.print_stock == "kodak_portra_endura"
                ? "fujifilm_crystal_archive_typeii" : "kodak_portra_endura";
            auto unchanged = host.render(settings);
            check(unchanged->reprint() && unchanged->negative_was_cached(), "slide paper edit missed the cached film");
            if (frame_fingerprint(*unchanged) != pixels_before ||
                fingerprint(unchanged->bgra8.data(), unchanged->bgra8.size()) != display_before)
                throw std::runtime_error("Paper controls changed directly scanned slide pixels: " + id);
            check(unchanged->settings.print_stock == settings.print_stock &&
                  unchanged->settings.print_exposure == settings.print_exposure,
                  "slide discarded remembered paper preferences");
            renders.push(frame_report(*unchanged));
            if (!held) {
                held = current;
                held_pixels = pixels_before;
                held_display = display_before;
            }
            current = std::move(unchanged);
        }
        settings.film_stock = "kodak_portra_400";
        auto negative = host.render(settings);
        check(!negative->scan_film, "returning to negative film retained direct scan");
        check(!negative->reprint() && !negative->negative_was_cached(), "negative transition reused a slide negative");
        check(negative->settings.print_stock == settings.print_stock &&
              negative->settings.print_exposure == settings.print_exposure,
              "negative transition lost remembered paper preferences");
        const auto negative_pixels = frame_fingerprint(*negative);
        settings.print_exposure *= 1.5;
        auto print = host.render(settings);
        check(print->reprint() && print->negative_was_cached(), "negative paper edit missed the cached film");
        check(frame_fingerprint(*print) != negative_pixels, "negative transition left paper exposure inactive");
        report.set("negative_return", frame_report(*print));
        settings.film_stock = slides.front();
        auto slide_return = host.render(settings);
        check(slide_return->scan_film && !slide_return->reprint() && !slide_return->negative_was_cached(),
              "negative-to-slide transition failed to restore direct scanning with a new film negative");
        report.set("slide_return", frame_report(*slide_return));
        host.export_tiff(*held, exported);
        compare_tiff(exported, *held, resources / "io/sRGB.icc");
        check(host.current() == slide_return, "held slide export changed the current frame");
    }
    check(frame_fingerprint(*held) == held_pixels &&
          fingerprint(held->bgra8.data(), held->bgra8.size()) == held_display,
          "film transitions or host destruction mutated held slide pixels");
    compare_tiff(exported, *held, resources / "io/sRGB.icc");
    report.set("status", Json(std::string("passed")));
    report.set("slides", std::move(renders));
    report.set("checks", Json(double(checks)));
    report.set("raw", Json(path_text(raw)));
    report.set("exported_tiff", Json(path_text(exported)));
    report.set("pixel_comparison", Json(std::string("Paper edits reuse the same film grain realisation and must not change directly scanned slide RGBA16/BGRA8. Held slide TIFF matches every RGB16 sample after film transitions and host destruction.")));
    std::ofstream stream(destination / "film-policy.json", std::ios::binary);
    check(bool(stream << report.dump() << '\n') && bool(stream.flush()), "cannot write film policy report");
}

// The settings table through the real engine, on a synthetic frame: no RAW
// needed. Grain and glare are off, so equal settings must give equal pixels.
struct Rendered {
    spk_result result{};
    Rendered() = default;
    Rendered(const Rendered&) = delete;
    Rendered& operator=(const Rendered&) = delete;
    ~Rendered() { spk_result_free(&result); }
    std::uint64_t pixels() const {
        std::uint64_t hash = 14695981039346656037ull;
        for (std::uint32_t y = 0; y < result.height; ++y)
            hash = fingerprint(result.rgba16 + std::size_t(y) * result.row_stride_px * 4,
                               std::size_t(result.width) * 4 * sizeof(std::uint16_t), hash);
        return hash;
    }
    double distance(const Rendered& other) const {
        check(result.width == other.result.width && result.height == other.result.height, "render size changed");
        double sum = 0.0;
        for (std::uint32_t y = 0; y < result.height; ++y)
            for (std::uint32_t x = 0; x < result.width * 4; ++x)
                sum += std::abs(double(result.rgba16[std::size_t(y) * result.row_stride_px * 4 + x]) -
                                double(other.result.rgba16[std::size_t(y) * other.result.row_stride_px * 4 + x]));
        return sum;
    }
    // The largest |R-G| or |B-G| over the frame, as a fraction of full scale:
    // 0 for a print with no colour anywhere.
    double channel_spread() const {
        int worst = 0;
        for (std::uint32_t y = 0; y < result.height; ++y)
            for (std::uint32_t x = 0; x < result.width; ++x) {
                const auto* p = result.rgba16 + (std::size_t(y) * result.row_stride_px + x) * 4;
                worst = std::max({worst, std::abs(int(p[0]) - int(p[1])), std::abs(int(p[2]) - int(p[1]))});
            }
        return worst / 65535.0;
    }
    // Mean of the green channel, as a fraction of full scale.
    double mean_green() const {
        double sum = 0.0;
        for (std::uint32_t y = 0; y < result.height; ++y)
            for (std::uint32_t x = 0; x < result.width; ++x)
                sum += result.rgba16[(std::size_t(y) * result.row_stride_px + x) * 4 + 1];
        return sum / (double(result.width) * result.height * 65535.0);
    }
};

// The catalogue the build deploys: spektrafilm's stocks and the product's own
// black-and-white films and silver paper, with the metadata macOS lists them by.
void real_catalogue(const Catalog& catalog) {
    const std::array<std::string, 4> silver_films{
        "kodak_tri_x_400", "kodak_tmax_100", "fujifilm_neopan_acros_100_ii", "ilford_hp5_plus_400"};
    for (const auto& id : silver_films) {
        const Stock* film = catalog.film(id);
        if (!film) throw std::runtime_error("deployed resources lack the black-and-white film " + id);
        check(film->is_monochrome && !film->is_positive && !film->is_cine &&
              film->target_print == "ilford_multigrade_iv_rc", "black-and-white film metadata");
    }
    const Stock* multigrade = catalog.paper("ilford_multigrade_iv_rc");
    check(multigrade && multigrade->is_monochrome && !multigrade->is_cine && multigrade->target_print.empty(),
          "deployed resources lack the silver paper");
    const Stock* portra = catalog.film("kodak_portra_400");
    const Stock* vision = catalog.film("kodak_vision3_500t");
    const Stock* provia = catalog.film("fujifilm_provia_100f");
    check(portra && !portra->is_monochrome && portra->target_print == "kodak_portra_endura" &&
          vision && vision->is_cine && vision->target_print == "kodak_2383" &&
          provia && provia->is_positive && provia->target_print.empty() &&
          catalog.paper("kodak_2383") && catalog.paper("kodak_2383")->is_cine, "colour stock metadata");
    // macOS's catalogue: 24 films and 9 papers (StockCatalog.json).
    check(catalog.films.size() == 24 && catalog.papers.size() == 9, "deployed catalogue size");
    for (const Stock& film : catalog.films)
        check(film.is_positive ? film.target_print.empty() : catalog.paper(film.target_print) != nullptr,
              "a negative names a paper the catalogue lacks, or a slide names one");
    const auto films = film_groups(catalog);
    check(films.size() == 3 && films[2].key == "blackAndWhite" && films[2].stocks.size() == silver_films.size() &&
          films[0].stocks.size() == 4 && films[1].stocks.size() == 16, "deployed film groups");
    for (const Stock* s : films[1].stocks) check(!s->is_monochrome && !s->is_positive, "a negative group member");
    // Within a group, stills before cine.
    bool cine = false;
    for (const Stock* s : films[1].stocks) {
        check(!cine || s->is_cine, "a still film follows a cine film");
        cine = cine || s->is_cine;
    }
    const auto papers = paper_groups(catalog);
    check(papers[0].stocks.size() == 7 && papers[1].stocks.size() == 2 &&
          std::any_of(papers[0].stocks.begin(), papers[0].stocks.end(),
                      [](const Stock* s) { return s->id == "ilford_multigrade_iv_rc"; }), "deployed paper groups");
}

void settings_engine(const fs::path& resources) {
    using EnginePtr = std::unique_ptr<spk_engine, decltype(&spk_engine_destroy)>;
    using SessionPtr = std::unique_ptr<spk_session, decltype(&spk_session_release)>;
    const auto catalog = read_catalog(resources);
    real_catalogue(catalog);
    const auto root = path_text(fs::absolute(resources));
    EnginePtr engine(spk_engine_create(root.c_str(), nullptr), &spk_engine_destroy);
    if (!engine) throw std::runtime_error(std::string("engine: ") + spk_last_error(nullptr));
    const auto error = [&] { return std::string(spk_last_error(engine.get())); };
    // A smooth, non-uniform frame, so the metering intents disagree.
    constexpr std::uint32_t width = 96, height = 64;
    std::vector<float> rgb(std::size_t(width) * height * 3);
    for (std::uint32_t y = 0; y < height; ++y)
        for (std::uint32_t x = 0; x < width; ++x) {
            float* p = rgb.data() + (std::size_t(y) * width + x) * 3;
            p[0] = 0.01f + 0.9f * float(x) / (width - 1);
            p[1] = 0.01f + 0.5f * float(y) / (height - 1);
            p[2] = 0.03f + 0.3f * float(x + y) / (width + height - 2);
        }
    const spk_image input{rgb.data(), width, height, 3};
    RenderSettings current;
    current.grain_active = false;
    current.glare_active = false;
    const auto open = [&](const RenderSettings& settings) {
        SessionPtr s(spk_open(engine.get(), &input, opening_params(settings, catalog).dump().c_str(), nullptr),
                     &spk_session_release);
        if (!s) throw std::runtime_error("open " + settings.film_stock + " on " + settings.print_stock + ": " + error());
        return s;
    };
    const auto session_params = [&](spk_session* s) {
        char* text = nullptr;
        check(spk_get_params(s, &text) == SPK_OK && text, "read session parameters");
        Json params;
        std::string parse_error;
        const bool parsed = Json::parse(text, params, parse_error);
        spk_string_free(text);
        check(parsed, "session parameters are not JSON");
        return params;
    };
    SessionPtr session = open(current);
    // The session holds exactly what the table sent, macOS defaults and the
    // product's wire rules included.
    const auto session_matches = [&](const RenderSettings& settings) {
        const Json params = session_params(session.get());
        const Json wire = wire_params(settings, catalog);
        for (const auto& [key, value] : wire.fields())
            if (!same_json(params.at(key), value))
                throw std::runtime_error("session does not hold the table's " + key + ": " + params.at(key).dump());
        return params;
    };
    session_matches(current);
    Rendered opened;
    check(spk_render(session.get(), "full", &opened.result) == SPK_OK, "first render");

    // What a frame is tagged with comes from the engine's reply: the
    // desktop's sRGB request, a ProPhoto request, and no request at all --
    // where only the engine knows the answer (its RFC-018 default).
    const auto resolved = [&](const Json& params) {
        char* text = nullptr;
        SessionPtr probe(spk_open(engine.get(), &input, params.dump().c_str(), &text), &spk_session_release);
        const std::unique_ptr<char, decltype(&spk_string_free)> owner(text, &spk_string_free);
        if (!probe || !text) throw std::runtime_error("open for the encoding probe: " + error());
        Json reply;
        std::string parse_error;
        check(Json::parse(text, reply, parse_error), "open reply is not JSON");
        return output_encoding(reply);
    };
    check(resolved(opening_params(current, catalog)) == OutputEncoding{"sRGB", true},
          "the desktop's sRGB session reports another encoding");
    check(resolved(opening_params(current, catalog, "ProPhoto RGB")) == OutputEncoding{"ProPhoto RGB", true},
          "a ProPhoto session reports another encoding");
    Json unrequested = Json::object();
    const Json requested = opening_params(current, catalog);
    for (const auto& kv : requested.fields())
        if (kv.first != "output_color_space" && kv.first != "output_cctf_encoding") unrequested.set(kv.first, kv.second);
    const auto engine_default = resolved(unrequested);
    check(engine_default == OutputEncoding{spk::Params{}.io.output_color_space, true} &&
          engine_default.color_space != kDisplayOutputColorSpace,
          "an unrequested output space did not come back as the engine's own default");

    const auto edit = [&](const RenderSettings& next, bool expect_cached) {
        const auto delta = changed_params(current, next, catalog);
        check(!delta.fields().empty(), "edit produced no delta");
        if (spk_set_params(session.get(), delta.dump().c_str(), nullptr) != SPK_OK)
            throw std::runtime_error("apply " + delta.dump() + ": " + error());
        auto out = std::make_unique<Rendered>();
        check(spk_reprint(session.get(), "full", &out->result) == SPK_OK, "reprint after edit");
        check((out->result.negative_was_cached != 0) == expect_cached, "edit used the wrong film-cache path");
        current = next;
        session_matches(current);
        return out;
    };

    auto next = current;
    next.print_exposure = 0.8;
    const auto brighter = edit(next, true);
    check(brighter->pixels() != opened.pixels(), "print exposure did not change the print");
    // The scale multiplies the shifts and nothing else: at zero shifts the
    // engine's 1 and macOS's 40 print identically. This is why a version-1
    // edit with both shifts at zero can take the new strength unchanged.
    next.set("filter_shift_scale", 1.0);
    const auto unscaled = edit(next, true);
    check(unscaled->pixels() == brighter->pixels(), "filter scale moved a print with zero shifts");
    next.y_filter_shift = 0.25;
    const auto weak = edit(next, true);
    next.set("filter_shift_scale", 40.0);
    const auto strong = edit(next, true);
    check(strong->distance(*unscaled) > 4.0 * weak->distance(*unscaled) && strong->distance(*unscaled) > 0,
          "filter_shift_scale 40 does not strengthen the yellow filter");
    next.set("auto_exposure_method", std::string("center_weighted"));
    const auto metered = edit(next, false);
    check(metered->pixels() != strong->pixels(), "metering intent did not change the render");

    // The rows the macOS Film and Print sections add. Print side: pre-flash
    // reprints the cached negative, and Print Effects off prints exactly as
    // without it (glare is already off here), on again exactly as with it.
    next.set("preflash_exposure", 0.01);
    const auto flashed = edit(next, true);
    check(flashed->pixels() != metered->pixels(), "pre-flash did not change the print");
    next.set("print_effects", false);
    const auto plain = edit(next, true);
    check(plain->pixels() == metered->pixels(), "Print Effects off still printed the pre-flash");
    next.set("print_effects", true);
    check(edit(next, true)->pixels() == flashed->pixels(), "Print Effects on lost the pre-flash");
    // No Print Profile scans the cached negative instead of printing it.
    next.set("scan_film", true);
    const auto negative_scan = edit(next, true);
    check(negative_scan->pixels() != flashed->pixels(), "No Print Profile still printed");
    next.set("scan_film", false);
    check(edit(next, true)->pixels() == flashed->pixels(), "No Print Profile off did not print again");
    // Film side: each re-develops. The meter off and the couplers move this
    // frame; scatter, highlight boost and the anti-halation layer act on
    // highlights and edges this smooth frame barely has, so the session
    // holding them (edit checks it) and the final fresh-open equality are
    // their checks. Grain is off, so its model cannot move a pixel.
    next.set("auto_exposure", false);
    const auto unmetered = edit(next, false);
    check(unmetered->pixels() != flashed->pixels(), "auto exposure off did not change the render");
    next.set("dir_couplers_amount", 0.5);
    const auto couplers = edit(next, false);
    check(couplers->pixels() != unmetered->pixels(), "couplers amount did not change the render");
    next.set("halation_scatter_amount", 0.5);
    (void)edit(next, false);
    next.set("halation_boost_ev", 2.0);
    (void)edit(next, false);
    next.set("antihalation_removed", true);
    (void)edit(next, false);
    next.set("grain_sublayers_active", false);
    (void)edit(next, false);
    next.set("dir_couplers_active", false);
    (void)edit(next, false);

    next.print_stock = "kodak_portra_endura";
    (void)edit(next, true);
    next.film_stock = "kodak_ektar_100";
    (void)edit(next, false);
    next.film_stock = "kodak_ektachrome_100";
    (void)edit(next, false);
    check(session_params(session.get()).at("scan_film").as_bool(), "a slide was printed");
    next.film_stock = "kodak_portra_400";
    (void)edit(next, false);

    // Black and white on its paper, coming from a colour pair: the delta lands
    // where a fresh open does (Multigrade filter 2, one grain layer), the print
    // is neutral, and going back the engine reloads the colour pair's pack.
    next.film_stock = "kodak_tri_x_400";
    next.print_stock = "ilford_multigrade_iv_rc";
    const auto silver = edit(next, false);
    const Json silver_params = session_matches(current);
    if (silver_params.at("y_filter_neutral").as_double() != 68.0 || silver_params.at("m_filter_neutral").as_double() != 0.0 ||
        silver_params.at("grain_sublayers_active").as_bool())
        throw std::runtime_error("the silver pair lacks its pack or kept sub-layer grain: M " +
                                 silver_params.at("m_filter_neutral").dump() + " Y " +
                                 silver_params.at("y_filter_neutral").dump());
    {
        SessionPtr fresh = open(current);
        Rendered reopened;
        check(spk_render(fresh.get(), "full", &reopened.result) == SPK_OK, "render a fresh black-and-white session");
        check(reopened.pixels() == silver->pixels(), "a black-and-white edit differs from a fresh black-and-white open");
    }
    check(silver->channel_spread() < 2e-3, "a black-and-white print has colour in it");
    next.film_stock = "kodak_portra_400";
    next.print_stock = "kodak_supra_endura";
    const auto colour = edit(next, false);
    // The Pre-Dev rows. The Tone Mask is a print edit: it reprints the cached
    // negative (API-SPEC §11) and moves the print. A resolved Scene Placement
    // curve -- what the Fit would commit -- is a shoot edit and re-develops
    // (API-SPEC §12); a highlight knee half a stop over the metered mid-grey
    // reaches into this frame, which runs about two stops over it. Both are
    // still on the session when Print Effects goes off below, and the fresh
    // open at the end holds them to what a session opened with them renders.
    next.set("contrast_mask_active", true);
    next.set("contrast_mask_highlights", 1.5);
    next.set("contrast_mask_shadows", 1.0);
    const auto masked = edit(next, true);
    check(masked->pixels() != colour->pixels(), "the tone mask did not change the print");
    next.set("scene_latitude_active", true);
    next.set("scene_latitude_highlight_knee", 0.5);
    next.set("scene_latitude_highlight_room", 1.5);
    const auto placed = edit(next, false);
    check(placed->pixels() != masked->pixels(), "a scene placement curve did not change the render");
    Json neutral_db;
    {
        std::ifstream file(resources / "neutral_print_filters.json", std::ios::binary);
        std::stringstream text;
        text << file.rdbuf();
        std::string parse_error;
        check(Json::parse(text.str(), neutral_db, parse_error), "read the engine's neutral filter table");
    }
    const Json& row = neutral_db.at("kodak_supra_endura").at("TH-KG3").at("kodak_portra_400");
    const Json back = session_params(session.get());
    check(row.is_array() && row.items().size() == 3 && back.at("c_filter_neutral").as_double() == row.items()[0].as_double() &&
          back.at("m_filter_neutral").as_double() == row.items()[1].as_double() &&
          back.at("y_filter_neutral").as_double() == row.items()[2].as_double(),
          "leaving the silver pair kept Multigrade's pack on a colour paper");
    // A product row away from its default is part of what a fresh open must
    // reproduce too.
    next.set("print_effects", false);
    const auto last = edit(next, true);
    // Deltas leave the session exactly where opening with the final settings
    // would have: nothing the table holds is lost across stock changes.
    SessionPtr fresh = open(current);
    Rendered reopened;
    check(spk_render(fresh.get(), "full", &reopened.result) == SPK_OK, "render reopened session");
    check(reopened.pixels() == last->pixels(), "edited session differs from a fresh one with the same settings");

    // Each black-and-white film on Multigrade IV RC at a new photograph's
    // settings (grain and glare off, so the frame is deterministic): a print
    // with no colour in it, and the film's own grain on the wire.
    for (const std::string film : {"kodak_tri_x_400", "kodak_tmax_100", "fujifilm_neopan_acros_100_ii",
                                   "ilford_hp5_plus_400"}) {
        RenderSettings bw;
        bw.grain_active = false;
        bw.glare_active = false;
        bw.film_stock = film;
        bw.print_stock = "ilford_multigrade_iv_rc";
        SessionPtr s = open(bw);
        Rendered print;
        check(spk_render(s.get(), "full", &print.result) == SPK_OK, "render a black-and-white film");
        const Json params = session_params(s.get());
        check(std::abs(params.at("grain_amount").as_double() - own_grain(film)) < 1e-12,
              "a black-and-white film's grain is not its own");
        const double spread = print.channel_spread(), mid = print.mean_green();
        std::cout << "black and white: " << film << " on Multigrade IV RC, channel spread " << spread
                  << ", mean " << mid << '\n';
        check(spread < 2e-3 && mid > 0.05 && mid < 0.95, "a black-and-white print is not a neutral picture");
    }
}

void integration(const fs::path& resources, const fs::path& arw,
                 const fs::path& nef, const fs::path& destination) {
    check(fs::create_directory(destination), "integration destination must be a new directory");
    Json report = Json::object();
    report.set("arw", Json(path_text(arw))); report.set("nef", Json(path_text(nef)));
    FramePtr first;
    std::uint64_t first_pixels = 0, first_display = 0;
    const auto exported = destination / fs::path(u8"\u5df2\u663e\u793a\u5e27-\u539f\u59cb16\u4f4d.tif");
    {
        PreviewHost host(resources);
        check(!host.current(), "new host already has a frame");
        report.set("engine_create_ms", Json(host.engine_create_ms()));
        const auto& catalog = host.catalog();
        check(catalog.films.size() > 1 && !catalog.papers.empty(), "desktop catalog unavailable");
        rejected([&] { host.render({}); }, "render before open accepted");
        first = host.open_raw(arw, DecodeMode::compatible16);
        check(first && first == host.current(), "successful open did not publish its frame");
        check(first->width() == 4688 && first->height() == 7028, "full Sony ARW fixture dimensions differ");
        check(!first->reprint() && !first->negative_was_cached() && !first->metadata.headroom_enabled,
              "first compatible open has incorrect cache/mode flags");
        check(first->bgra8.size() == std::size_t(first->width()) * first->height() * 4,
              "display does not contain full-resolution pixels");
        first_pixels = frame_fingerprint(*first);
        first_display = fingerprint(first->bgra8.data(), first->bgra8.size());
        report.set("first_open", frame_report(*first));

        RenderSettings print_edit = first->settings;
        print_edit.print_exposure = 1.25;
        auto edited = host.render(print_edit);
        check(edited && edited != first && edited->reprint() && edited->negative_was_cached(),
              "print exposure edit did not reuse negative cache");
        check(edited->settings.print_exposure == 1.25 && edited->timings.decode_ms == 0 && edited->timings.open_ms == 0,
              "print edit changed settings incorrectly or reopened RAW");
        report.set("print_edit", frame_report(*edited));
        const auto nef_error = rejected([&] { host.open_raw(nef, DecodeMode::compatible16); }, "unsupported Nikon HE file opened");
        check(nef_error.find("Nikon HE/HE*") != std::string::npos, "Nikon failure lacks compression diagnosis");
        check(host.current() == edited, "failed Nikon open replaced prior frame");
        report.set("nef_failure", Json(nef_error));
        print_edit.print_exposure = 0.8;
        auto after_failure = host.render(print_edit);
        check(after_failure->reprint() && after_failure->negative_was_cached(), "Nikon open failure damaged reusable session");
        report.set("render_after_nef_failure", frame_report(*after_failure));

        for (unsigned variant = 0; variant < 4; ++variant) {
            auto invalid = print_edit;
            if (variant == 0) invalid.film_stock = "__missing_desktop_film__";
            if (variant == 1) invalid.print_stock = "__missing_desktop_paper__";
            if (variant == 2) invalid.print_exposure = 0;
            if (variant == 3) invalid.print_exposure = std::numeric_limits<double>::quiet_NaN();
            rejected([&] { host.render(invalid); }, "invalid render setting accepted");
            check(host.current() == after_failure, "invalid settings changed current frame");
        }
        auto film_edit = print_edit;
        const auto alternate = std::find_if(catalog.films.begin(), catalog.films.end(),
            [&](const Stock& stock) { return stock.id != film_edit.film_stock; });
        check(alternate != catalog.films.end(), "no alternate film for edit test");
        film_edit.film_stock = alternate->id;
        auto changed_film = host.render(film_edit);
        check(!changed_film->reprint() && !changed_film->negative_was_cached(), "film edit incorrectly reused old negative");
        check(changed_film->settings.film_stock == film_edit.film_stock, "film edit not reflected in frame");
        report.set("film_edit", frame_report(*changed_film));
        edited.reset(); after_failure.reset(); changed_film.reset();

        auto headroom = host.open_raw(arw, DecodeMode::headroom);
        check(headroom && headroom->metadata.headroom_enabled && headroom->decode_mode == DecodeMode::headroom &&
              headroom->width() == first->width() && headroom->height() == first->height(), "headroom reopen failed");
        report.set("headroom_open", frame_report(*headroom));
        check(frame_fingerprint(*first) == first_pixels &&
              fingerprint(first->bgra8.data(), first->bgra8.size()) == first_display,
              "later renders or opens modified previously displayed frame");
        // Export the original held stochastic result after newer frames exist.
        // Comparing two independently rendered stochastic images would be invalid.
        const auto export_start = std::chrono::steady_clock::now();
        host.export_tiff(*first, exported);
        report.set("export_ms", Json(std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - export_start).count()));
        compare_tiff(exported, *first, resources / "io/sRGB.icc");
        rejected([&] { host.export_tiff(*headroom, exported); }, "export overwrote existing TIFF");
        compare_tiff(exported, *first, resources / "io/sRGB.icc");
        check(host.current() == headroom, "export changed active frame");
    }
    check(frame_fingerprint(*first) == first_pixels &&
          fingerprint(first->bgra8.data(), first->bgra8.size()) == first_display,
          "display/result invalid after host and engine destruction");
    compare_tiff(exported, *first, resources / "io/sRGB.icc");
    first.reset();  // spk_result_free is intentionally exercised without engine.
    report.set("status", Json(std::string("passed")));
    report.set("checks", Json(double(checks)));
    report.set("held_rgba16_fnv1a64", Json(hex(first_pixels)));
    report.set("held_bgra8_fnv1a64", Json(hex(first_display)));
    report.set("exported_tiff", Json(path_text(exported)));
    report.set("pixel_comparison", Json(std::string("Every exported RGB16 sample equals the same held Frame; no second stochastic render used as oracle.")));
    report.set("limits", Json(std::string("Host integration only; no claim of visible-window, colour-managed monitor or interactive responsiveness verification.")));
    std::ofstream stream(destination / "integration.json", std::ios::binary);
    check(bool(stream << report.dump() << '\n') && bool(stream.flush()), "cannot write integration report");
}

}  // namespace

int main(int argc, char** argv) {
    try {
        settings_schema();
        settings_defaults();
        settings_access();
        settings_validation();
        catalogue_rules();
        wire_rules();
        settings_deltas();
        conversion();
        viewport_geometry();
        if (argc == 3 && std::string(argv[1]) == "--settings-engine") {
            settings_engine(fs::path(reinterpret_cast<const char8_t*>(argv[2])));
        } else if (argc == 5 && std::string(argv[1]) == "--film-policy") {
            film_policy(fs::path(reinterpret_cast<const char8_t*>(argv[2])),
                        fs::path(reinterpret_cast<const char8_t*>(argv[3])),
                        fs::path(reinterpret_cast<const char8_t*>(argv[4])));
        } else if (argc == 5 && std::string(argv[1]) == "--edit-controls") {
            edit_controls(fs::path(reinterpret_cast<const char8_t*>(argv[2])),
                          fs::path(reinterpret_cast<const char8_t*>(argv[3])),
                          fs::path(reinterpret_cast<const char8_t*>(argv[4])));
        } else if (argc != 1) {
            if (argc != 6 || std::string(argv[1]) != "--integration") {
                std::cerr << "usage: spk_desktop_preview_test [--integration <resources> <ARW> <NEF> <new-output-directory>]\n"
                             "       spk_desktop_preview_test --settings-engine <resources>\n"
                             "       spk_desktop_preview_test --film-policy <resources> <RAW> <new-output-directory>\n"
                             "       spk_desktop_preview_test --edit-controls <resources> <RAW> <new-output-directory>\n";
                return 2;
            }
            integration(fs::path(reinterpret_cast<const char8_t*>(argv[2])),
                        fs::path(reinterpret_cast<const char8_t*>(argv[3])),
                        fs::path(reinterpret_cast<const char8_t*>(argv[4])),
                        fs::path(reinterpret_cast<const char8_t*>(argv[5])));
        }
        std::cout << "Desktop preview boundary: " << checks << " checks passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
