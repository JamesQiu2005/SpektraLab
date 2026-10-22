// spektralab-host -- the engine as a child process (desktop/HOST-PROTOCOL.md).
//
// stdin/stdout carry length-prefixed frames (u32 header_len, u32 payload_len,
// JSON header, binary payload); stderr is a free-form log. A reader thread
// owns stdin: it answers `ping`, `cancel` and `shutdown` itself and queues
// everything else for one worker thread, which owns the engine. So requests
// run in order, a render can be cancelled while it runs, and a host that is
// busy still answers a liveness check.
//
// The engine is reached only through its C ABI (`spk_engine.h`), exactly as
// the macOS app reaches it -- the host is a client of the engine, not a
// second implementation of any of it.

#include <algorithm>
#include <fstream>
#include <iterator>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <thread>
#include <vector>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

#include "image_io.hpp"
#include "lens_correction.hpp"
#include "pair_source.hpp"
#include "white_balance.hpp"
#include "json.hpp"
#include "output.hpp"
#include "platform.hpp"
#include "spektrafilm/spk_engine.h"
#include "pipeline/view.hpp"

#ifndef SPEKTRALAB_HOST_VERSION
#define SPEKTRALAB_HOST_VERSION "0.1.0"
#endif

using spk::Json;
namespace fs = std::filesystem;
using namespace spkhost;

namespace {

constexpr int kProtocol = 1;
constexpr uint32_t kMaxHeader = 64u << 20;

using Clock = std::chrono::steady_clock;
double ms_since(Clock::time_point t) {
    return std::chrono::duration<double, std::milli>(Clock::now() - t).count();
}

// --- logging -------------------------------------------------------------------

int g_log_level = 1;   // 0 error, 1 info, 2 debug
std::mutex g_log_mutex;
void log_line(int level, const std::string& text) {
    if (level > g_log_level) return;
    std::lock_guard<std::mutex> lock(g_log_mutex);
    static const char* names[] = {"error", "info", "debug"};
    std::fprintf(stderr, "spektralab-host %s: %s\n", names[level], text.c_str());
    std::fflush(stderr);
}

// --- framing -------------------------------------------------------------------

std::mutex g_out_mutex;

void write_frame(const Json& header, const void* payload = nullptr, size_t payload_len = 0) {
    const std::string text = header.dump();
    uint8_t prefix[8];
    const uint32_t h = uint32_t(text.size()), p = uint32_t(payload_len);
    for (int i = 0; i < 4; ++i) { prefix[i] = uint8_t(h >> (8 * i)); prefix[4 + i] = uint8_t(p >> (8 * i)); }
    std::lock_guard<std::mutex> lock(g_out_mutex);
    std::fwrite(prefix, 1, 8, stdout);
    std::fwrite(text.data(), 1, text.size(), stdout);
    if (payload_len) std::fwrite(payload, 1, payload_len, stdout);
    std::fflush(stdout);
}

bool read_exact(void* dst, size_t n) {
    uint8_t* p = static_cast<uint8_t*>(dst);
    while (n) {
        const size_t got = std::fread(p, 1, n, stdin);
        if (got == 0) return false;
        p += got;
        n -= got;
    }
    return true;
}

struct Request {
    uint32_t id = 0;
    std::string method;
    Json params = Json::object();
    std::vector<uint8_t> payload;
};

struct HostError {
    std::string code, message;
};

Json number(double v) { return Json(v); }
Json str(const std::string& s) { return Json(s); }

void respond_ok(uint32_t id, Json result, const void* payload = nullptr, size_t n = 0) {
    Json h = Json::object();
    h.set("id", number(id));
    h.set("ok", Json(true));
    h.set("result", std::move(result));
    write_frame(h, payload, n);
}

void respond_error(uint32_t id, const std::string& code, const std::string& message) {
    Json e = Json::object();
    e.set("code", str(code));
    e.set("message", str(message));
    Json h = Json::object();
    h.set("id", number(id));
    h.set("ok", Json(false));
    h.set("error", std::move(e));
    write_frame(h);
    log_line(2, "request " + std::to_string(id) + " failed: " + code + ": " + message);
}

void emit_event(Json event) { write_frame(event); }

// --- state ---------------------------------------------------------------------

struct Session {
    std::string id;
    spk_session* handle = nullptr;
    std::string path;
    uint32_t width = 0, height = 0;
    Metadata metadata;
    std::optional<spk::io::RawMetadata> raw_metadata;
    std::string output_space = "ProPhoto RGB";
    DecodeOptions decode;
    std::unique_ptr<PairSource> pair_source;
    Json pair, pair_info;
    std::string pair_signature;
    std::array<std::optional<spk::io::RawMetadata>, 2> pair_raw_metadata;
    std::array<double, 2> pair_gains{1., 1.};
};

struct State {
    fs::path resources;
    spk_engine* engine = nullptr;
    std::string engine_error;
    std::map<std::string, std::shared_ptr<Session>> sessions;
    std::mutex sessions_mutex;   // the reader thread reads `sessions` for cancel
    uint64_t next_session = 1;
    std::map<std::string, OutputTransform> transforms;

    // cancellation
    std::mutex cancel_mutex;
    std::string running_session, running_requested_session, running_progress;
    bool running_active = false;
    std::set<std::pair<std::string, std::string>> cancelled;   // (session, progress_id) not yet started
    bool running_cancelled = false;
} g;

std::shared_ptr<Session> find_session(const Json& params, bool restore_pixels = true) {
    const std::string id = params.at("session").as_string();
    std::shared_ptr<Session> session;
    {
        std::lock_guard<std::mutex> lock(g.sessions_mutex);
        auto it = g.sessions.find(id);
        if (it == g.sessions.end()) throw HostError{"not_found", "no session '" + id + "'"};
        session = it->second;
    }
    // Only the worker changes residency. Keep the registry available to the
    // cancellation reader while restoring a potentially large cached frame.
    std::string error;
    if (restore_pixels && !spk::view::resume(session->handle, error))
        throw HostError{"io_error", "cannot restore editor cache: " + error};
    return session;
}

[[noreturn]] void engine_fail(spk_status status, const std::string& what) {
    const std::string message = what + ": " + spk_last_error(g.engine);
    if (status == SPK_ERR_CANCELLED) throw HostError{"cancelled", message};
    if (status == SPK_ERR_UNSUPPORTED) throw HostError{"unsupported", message};
    if (status == SPK_ERR_INVALID_ARG || status == SPK_ERR_USER) throw HostError{"bad_request", message};
    if (status == SPK_ERR_IO) throw HostError{"io_error", message};
    throw HostError{"engine_error", message};
}

void need_engine() {
    if (!g.engine) throw HostError{"engine_error", "the engine did not start: " + g.engine_error};
}

Json parse_json(const char* text) {
    Json out;
    std::string error;
    if (!text || !Json::parse(text, out, error)) throw HostError{"internal", "engine returned unparsable JSON: " + error};
    return out;
}

Json take_json(char* text) {
    Json out;
    std::string error;
    const bool ok = text && Json::parse(text, out, error);
    if (text) spk_string_free(text);
    if (!ok) throw HostError{"internal", "engine returned unparsable JSON: " + error};
    return out;
}

const std::string& require_string(const Json& params, const char* key) {
    const Json& v = params.at(key);
    if (!v.is_string() || v.as_string().empty()) throw HostError{"bad_request", std::string("missing string '") + key + "'"};
    return v.as_string();
}

std::string optional_string(const Json& params, const char* key, const std::string& fallback = {}) {
    const Json& v = params.at(key);
    return v.is_string() ? v.as_string() : fallback;
}

std::string iso_datetime(const std::string& exif) {
    // "YYYY:MM:DD HH:MM:SS" -> "YYYY-MM-DDTHH:MM:SS"
    if (exif.size() >= 19 && exif[4] == ':' && exif[7] == ':') {
        std::string s = exif.substr(0, 19);
        s[4] = '-'; s[7] = '-'; s[10] = 'T';
        return s;
    }
    return exif;
}

Json metadata_json(const Metadata& m) {
    Json j = Json::object();
    if (!m.make.empty()) j.set("make", str(m.make));
    if (!m.model.empty()) j.set("model", str(m.model));
    if (!m.lens.empty()) j.set("lens", str(m.lens));
    if (m.iso) j.set("iso", number(*m.iso));
    if (m.shutter_s) j.set("shutter_s", number(*m.shutter_s));
    if (m.aperture) j.set("aperture", number(*m.aperture));
    if (m.focal_mm) j.set("focal_mm", number(*m.focal_mm));
    if(m.lens_correction) {
        const auto& lens=*m.lens_correction;Json info=Json::object();
        info.set("available",Json(lens.available));info.set("applied",Json(lens.applied));
        info.set("profile",str(lens.profile));info.set("reason",str(lens.reason));
        info.set("distortion",Json(lens.distortion));info.set("tca",Json(lens.tca));info.set("vignetting",Json(lens.vignetting));
        info.set("scale",number(lens.scale));
        info.set("focus_distance_m",number(lens.focus_distance_m));
        info.set("focus_distance_assumed",Json(lens.focus_distance_assumed));
        j.set("lens_correction",std::move(info));
    }
    if (m.exposure_program) j.set("exposure_program", number(*m.exposure_program));
    if (m.exposure_bias_ev) j.set("exposure_bias_ev", number(*m.exposure_bias_ev));
    if (m.focal_35mm) j.set("focal_35mm", number(*m.focal_35mm));
    if (!m.datetime_original.empty()) j.set("datetime_original", str(iso_datetime(m.datetime_original)));
    j.set("orientation", number(m.orientation));
    if (m.as_shot_temperature_k && m.as_shot_tint) {
        Json a = Json::object();
        a.set("temperature_k", number(std::round(*m.as_shot_temperature_k)));
        a.set("tint", number(std::round(*m.as_shot_tint * 10) / 10));
        j.set("as_shot", std::move(a));
    }
    return j;
}

Exif exif_of(const Metadata& m) {
    Exif e;
    e.make = m.make;
    e.model = m.model;
    e.lens = m.lens;
    e.datetime_original = m.datetime_original;
    e.iso = m.iso.value_or(0);
    e.shutter_s = m.shutter_s.value_or(0);
    e.aperture = m.aperture.value_or(0);
    e.focal_mm = m.focal_mm.value_or(0);
    e.exposure_program = m.exposure_program; e.exposure_bias_ev = m.exposure_bias_ev; e.focal_35mm = m.focal_35mm;
    e.extra = m.extra_exif;
    return e;
}

std::string output_space_of(const Json& params) {
    const Json& nested = params.path("io.output_color_space");
    if (nested.is_string()) return nested.as_string();
    const Json& flat = params.at("output_color_space");
    if (flat.is_string()) return flat.as_string();
    return "ProPhoto RGB";
}

const OutputTransform& transform(const std::string& src, const std::string& dst) {
    const std::string key = src + "->" + dst;
    auto it = g.transforms.find(key);
    if (it != g.transforms.end()) return it->second;
    OutputTransform t;
    std::string error;
    if (!t.fetch(g.engine, src, dst, error)) throw HostError{"engine_error", "output transform " + key + ": " + error};
    return g.transforms.emplace(key, std::move(t)).first->second;
}

// Holds a spk_result and frees it.
struct Result {
    spk_result r{};
    ~Result() { if (r.texture) spk_result_free(&r); }
};

// Engine pixels -> the requested wire format. Fills `image` and `payload`.
void package_pixels(const spk_result& r, const std::string& source_space, const Json& params, Json& image,
                    std::vector<uint8_t>& payload) {
    const std::string format = optional_string(params, "format", "rgba8");
    std::string display = optional_string(params, "display");
    if (format != "rgba8" && format != "rgba16") throw HostError{"bad_request", "format must be rgba8 or rgba16"};
    if (format == "rgba8" && display.empty()) display = "srgb";
    const uint32_t w = r.width, h = r.height, stride = r.row_stride_px ? r.row_stride_px : r.width;
    image = Json::object();
    image.set("width", number(w));
    image.set("height", number(h));
    image.set("format", str(format));
    if (format == "rgba16" && display.empty()) {
        payload.resize(size_t(w) * h * 8);
        for (uint32_t y = 0; y < h; ++y) {
            const uint16_t* row = r.rgba16 + size_t(y) * stride * 4;
            uint8_t* out = &payload[size_t(y) * w * 8];
            for (size_t i = 0; i < size_t(w) * 4; ++i) { out[2 * i] = uint8_t(row[i]); out[2 * i + 1] = uint8_t(row[i] >> 8); }
        }
        image.set("color_space", str(source_space));
        image.set("row_bytes", number(double(w) * 8));
        return;
    }
    const std::string target = engine_space_name(display);
    if (target.empty()) throw HostError{"bad_request", "display must be srgb, display-p3 or prophoto"};
    const OutputTransform& t = transform(source_space, target);
    std::vector<float> lin;
    t.to_linear(r.rgba16, w, h, stride, lin);
    if (format == "rgba8") {
        t.encode_rgba8(lin, payload);
        image.set("row_bytes", number(double(w) * 4));
    } else {
        std::vector<uint16_t> px;
        t.encode_rgba16(lin, px);
        payload.resize(px.size() * 2);
        for (size_t i = 0; i < px.size(); ++i) { payload[2 * i] = uint8_t(px[i]); payload[2 * i + 1] = uint8_t(px[i] >> 8); }
        image.set("row_bytes", number(double(w) * 8));
    }
    image.set("color_space", str(target));
}

void progress_event(const Session& s, const std::string& progress_id, double fraction, const char* stage) {
    if (progress_id.empty()) return;
    Json e = Json::object();
    e.set("event", str("progress"));
    e.set("session", str(s.id));
    e.set("progress_id", str(progress_id));
    e.set("fraction", number(fraction));
    e.set("stage", str(stage));
    emit_event(std::move(e));
}

// Marks the session/progress pair as the one in flight; throws if it was
// cancelled while queued.
struct Running {
    Running(const std::string& session, const std::string& progress) {
        std::lock_guard<std::mutex> lock(g.cancel_mutex);
        if (!progress.empty() && (g.cancelled.erase({session, progress}) || g.cancelled.erase({"", progress})))
            throw HostError{"cancelled", "cancelled before it started"};
        g.running_session = session;
        g.running_requested_session = session;
        g.running_progress = progress;
        g.running_active = true;
        g.running_cancelled = false;
    }
    ~Running() {
        std::lock_guard<std::mutex> lock(g.cancel_mutex);
        g.running_session.clear();
        g.running_requested_session.clear();
        g.running_progress.clear();
        g.running_active = false;
    }
    void bind(const std::string& session) {
        std::lock_guard<std::mutex> lock(g.cancel_mutex);
        g.running_session = session;
    }
};

void check_cancelled() {
    std::lock_guard<std::mutex> lock(g.cancel_mutex);
    if (g.running_cancelled) throw HostError{"cancelled", "operation cancelled"};
}

// --- methods -------------------------------------------------------------------

Json m_hello(const Request&) {
    Json r = Json::object();
    r.set("protocol", number(kProtocol));
    r.set("host_version", str(SPEKTRALAB_HOST_VERSION));
    r.set("build_info", str(spk_build_info()));
    r.set("resources_dir", str(path_utf8(g.resources)));
    Json thumbnail_options = Json::array(); thumbnail_options.push(str("embedded-only"));
    r.set("thumbnail_options", std::move(thumbnail_options));
    Json backend = Json::object();
    backend.set("api", str("vulkan"));
    if (!g.engine) {
        backend.set("available", Json(false));
        backend.set("error", str(g.engine_error));
        r.set("backend", std::move(backend));
        r.set("capabilities", Json());
        return r;
    }
    Json caps = parse_json(spk_capabilities(g.engine));
    const Json& b = caps.at("backend");
    backend.set("available", Json(true));
    backend.set("device_name", str(b.at("gpu").as_string()));
    backend.set("math_mode", str(b.at("math_mode").as_string()));
    backend.set("render_core", str(b.at("render_core").as_string()));
    r.set("backend", std::move(backend));
    r.set("capabilities", std::move(caps));
    Json methods = Json::array();
    for (const char* m : {"hello", "ping", "shutdown", "params_schema", "print_lut_catalog", "memory_report",
                          "probe", "thumbnail", "open", "redecode", "close", "set_params", "get_params", "solve", "render",
                          "scene_latitude", "overscan_geometry", "preview_stock_lut", "cancel", "progress", "open_pair", "update_pair",
                          "export_image", "export_cube", "export_di", "export_cineon", "write_image", "render_view", "export_frame", "render_proof", "render_source", "pick_neutral"})
        methods.push(str(m));
    r.set("methods", std::move(methods));
    Json view_formats = Json::array(); view_formats.push(str("rgba8")); view_formats.push(str("rgba16"));
    r.set("view_formats", std::move(view_formats));
    Json spaces = Json::array();
    for (const char* space : {"sRGB", "display-p3", "prophoto", "adobe-rgb", "rec2020"}) spaces.push(str(space));
    r.set("export_spaces", std::move(spaces));
    Json tiff_options = Json::array();
    tiff_options.push(str("lzw")); tiff_options.push(str("preview-page"));
    r.set("tiff_options", std::move(tiff_options));
    return r;
}

Json m_params_schema(const Request&) { need_engine(); return parse_json(spk_params_schema(g.engine)); }
Json m_print_lut_catalog(const Request&) { need_engine(); return parse_json(spk_print_lut_catalog(g.engine)); }
Json m_memory_report(const Request&) { need_engine(); return parse_json(spk_memory_report(g.engine)); }


bool pair_path(const fs::path& path) {
    auto ext = path.extension().wstring();
    std::transform(ext.begin(), ext.end(), ext.begin(), ::towlower);
    return ext == L".spektrapair";
}
Json read_pair(const fs::path& path) {
    std::error_code ec;
    const auto size = fs::file_size(path, ec);
    if (ec) throw HostError{"not_found", "cannot read half-frame pair: " + path_utf8(path)};
    if (size > (1u << 20)) throw HostError{"bad_request", "pair recipe exceeds 1 MiB"};
    std::vector<uint8_t> bytes; std::string error;
    if (!read_file(path, bytes, error)) throw HostError{"io_error", error};
    Json pair;
    if (!Json::parse(std::string(bytes.begin(), bytes.end()), pair, error)) throw HostError{"bad_request", "invalid pair JSON: " + error};
    return pair;
}
Json pair_info(const PairSource::Description& d, const std::array<std::optional<double>,2>& metered = {}) {
    Json info = Json::object(); const char* sides[] = {"left", "right"};
    for (size_t i = 0; i < 2; ++i) {
        const auto& probe = d.probes[i]; Json hole = Json::object();
        hole.set("width", number(probe.width)); hole.set("height", number(probe.height));
        hole.set("kind", str(kind_name(probe.kind))); hole.set("metadata", metadata_json(probe.metadata));
        hole.set("available", Json(d.available[i]));
        if (!d.errors[i].empty()) hole.set("error", str(d.errors[i]));
        if (metered[i]) { hole.set("metered_ev", number(*metered[i])); hole.set("metered_for", str(d.meter_keys[i])); }
        info.set(sides[i], std::move(hole));
    }
    info.set("gates", d.gates); return info;
}
Json pair_view_recipe(const Session& session, const Json* snapshot = nullptr) {
    Json recipe = snapshot ? *snapshot : session.pair;
    Json gates = Json::array();
    for (const auto& rect : session.pair_info.at("gates").items()) {
        Json gate = Json::array();
        const double x = rect.at("x").as_double(), y = rect.at("y").as_double();
        gate.push(number(x)); gate.push(number(y));
        gate.push(number(x + rect.at("width").as_double())); gate.push(number(y + rect.at("height").as_double()));
        gates.push(std::move(gate));
    }
    recipe.set("gates", std::move(gates)); return recipe;
}

Json m_probe(const Request& q) {
    Probe p;
    std::string error;
    const fs::path path = utf8_path(require_string(q.params, "path"));
    if (pair_path(path)) {
        const auto description = PairSource::describe(read_pair(path));
        Json r = Json::object(); r.set("kind", str("pair"));
        r.set("width", number(description.width)); r.set("height", number(description.height));
        const size_t first = description.available[0] ? 0 : 1;
        r.set("metadata", metadata_json(description.probes[first].metadata));
        r.set("pair_info", pair_info(description)); return r;
    }
    if (!probe_file(path, p, error)) {
        std::error_code ec;
        throw HostError{fs::exists(path, ec) ? "decode_failed" : "not_found", error};
    }
    Json r = Json::object();
    r.set("kind", str(kind_name(p.kind)));
    r.set("width", number(p.width));
    r.set("height", number(p.height));
    r.set("metadata", metadata_json(p.metadata));
    return r;
}

Json m_thumbnail(const Request& q, std::vector<uint8_t>& payload) {
    const fs::path path = utf8_path(require_string(q.params, "path"));
    const uint32_t long_edge = uint32_t(std::max(1, q.params.at("long_edge").as_int(256)));
    if (q.params.has("embedded_only") && !q.params.at("embedded_only").is_bool())
        throw HostError{"bad_request", "embedded_only must be boolean"};
    const bool embedded_only = q.params.at("embedded_only").as_bool(false);
    Rgba8 t;
    std::string source, error;
    std::error_code ec;
    if (!fs::exists(path, ec)) throw HostError{"not_found", "not found: " + path_utf8(path)};
    if (pair_path(path)) {
        if (embedded_only) throw HostError{"unsupported", "embedded_only thumbnails require a RAW file"};
        Json recipe=read_pair(path);
        for (const char* side : {"left","right"}) if(recipe.at(side).is_object()) {
            Json hole=recipe.at(side);hole.set("autoExposure",Json(false));hole.set("exposureEV",number(0));recipe.set(side,std::move(hole));
        }
        PairSource composer;FloatImage pixels;PairSource::Description description;std::array<std::optional<double>,2> metered;
        auto decode=[&](const fs::path& file,const Json&,FloatImage& image,Probe& probe,std::string& why) {
            Rgba8 preview;std::string origin;
            if(!spkhost::thumbnail(file,std::min(8192u,long_edge*2),preview,origin,why))return false;
            if(!probe_file(file,probe,why))return false;
            image.width=preview.width;image.height=preview.height;image.rgb.resize(size_t(image.width)*image.height*3);
            for(size_t p=0;p<size_t(image.width)*image.height;++p)for(size_t c=0;c<3;++c)image.rgb[p*3+c]=preview.rgba[p*4+c]/255.f;
            return true;
        };
        if(!composer.compose(recipe,Json::object(),pixels,description,metered,decode,[](const FloatImage&,const std::string&){return 0.;},[]{},error,std::min(4096u,long_edge)))
            throw HostError{"decode_failed",error};
        t.width=pixels.width;t.height=pixels.height;t.rgba.resize(size_t(t.width)*t.height*4);
        for(size_t p=0;p<size_t(t.width)*t.height;++p){for(size_t c=0;c<3;++c)t.rgba[p*4+c]=uint8_t(std::lround(std::clamp(pixels.rgb[p*3+c],0.f,1.f)*255));t.rgba[p*4+3]=255;}
        source="pair-previews";
    } else if (!thumbnail(path, long_edge, t, source, error, embedded_only)) {
        if (error.rfind(kUnsupportedPrefix, 0) == 0)
            throw HostError{"unsupported", error.substr(std::strlen(kUnsupportedPrefix))};
        throw HostError{"decode_failed", error};
    }
    Json image = Json::object();
    image.set("width", number(t.width));
    image.set("height", number(t.height));
    image.set("format", str("rgba8"));
    image.set("color_space", str("sRGB"));
    image.set("row_bytes", number(double(t.width) * 4));
    Json r = Json::object();
    r.set("image", std::move(image));
    r.set("source", str(source));
    r.set("orientation_applied", Json(true));
    payload = std::move(t.rgba);
    return r;
}

DecodeOptions decode_options(const Json& decode) {
    DecodeOptions options;
    if (decode.is_null()) return options;
    if (!decode.is_object()) throw HostError{"bad_request", "decode must be an object"};
    options.raw_mode = optional_string(decode, "raw_mode", "compatible16");
    if (options.raw_mode != "compatible16" && options.raw_mode != "headroom")
        throw HostError{"bad_request", "decode.raw_mode must be compatible16 or headroom"};
    for (const auto& kv : decode.fields()) {
        if (kv.first == "raw_mode") continue;
        if (kv.first == "white_balance") {
            const Json& wb = kv.second;
            const std::string mode = optional_string(wb, "mode", "as_shot");
            if (mode == "as_shot") continue;
            if (mode != "custom") throw HostError{"bad_request", "white_balance.mode must be as_shot or custom"};
            const double t = wb.at("temperature_k").as_double(0);
            if (!(t >= 2000 && t <= 50000)) throw HostError{"bad_request", "white_balance.temperature_k must be 2000..50000"};
            const double tint = wb.at("tint").as_double(0);
            if (!(tint >= -150 && tint <= 150)) throw HostError{"bad_request", "white_balance.tint must be -150..150"};
            options.temperature_k = t;
            options.tint = tint;
        } else if (kv.first == "lens_correction") {
            if(!kv.second.is_bool())throw HostError{"bad_request","lens_correction must be boolean"};
            options.lens_correction=kv.second.as_bool(false);
        } else {
            throw HostError{"unsupported", "decode." + kv.first + " is not supported by this host"};
        }
    }
    return options;
}

struct Decoded {
    FloatImage frame;
    Probe probe;
    double decode_ms = 0;
};

Decoded decode_frame(const fs::path& path, const DecodeOptions& options) {
    std::error_code ec;
    if (!fs::exists(path, ec)) throw HostError{"not_found", "not found: " + path_utf8(path)};
    // Do this before LibRaw allocates, not only later in engine_open. Cached
    // session planes remain alive; only unused GPU scratch/staging is reclaimed.
    spk::view::trim_idle_memory(g.engine);
    const auto t0 = Clock::now();
    Decoded d;
    std::string error;
    if (!decode_linear_prophoto(path, options, d.frame, d.probe, error)) {
        const std::string prefix = kUnsupportedPrefix;
        if (error.rfind(prefix, 0) == 0) throw HostError{"unsupported", error.substr(prefix.size())};
        throw HostError{"decode_failed", error};
    }
    d.decode_ms = ms_since(t0);
    return d;
}

spk_session* engine_open(const FloatImage& frame, const std::string& delta, Json& opened, double& open_ms) {
    const auto t1 = Clock::now();
    spk_image image{frame.rgb.data(), frame.width, frame.height, 3};
    char* reply = nullptr;
    spk_session* handle = spk_open(g.engine, &image, delta.empty() ? nullptr : delta.c_str(), &reply);
    if (!handle) {
        if (reply) spk_string_free(reply);
        throw HostError{"engine_error", std::string("open: ") + spk_last_error(g.engine)};
    }
    opened = take_json(reply);
    open_ms = ms_since(t1);
    return handle;
}

Json open_reply(const Session& s, const Decoded& d, const Json& opened, double open_ms) {
    Json r = Json::object();
    r.set("session", str(s.id));
    r.set("width", number(d.frame.width));
    r.set("height", number(d.frame.height));
    r.set("kind", str(kind_name(d.probe.kind)));
    r.set("metadata", metadata_json(d.probe.metadata));
    r.set("params", opened.at("params"));
    r.set("detected_input", opened.at("detected_input"));
    r.set("output_color_space", str(s.output_space));
    Json timings = Json::object();
    timings.set("decode", number(d.decode_ms));
    timings.set("open", number(open_ms));
    if (d.frame.raw_timings) {
        const auto& t = *d.frame.raw_timings;
        Json raw = Json::object();
        raw.set("open", number(t.open_ms)); raw.set("unpack", number(t.unpack_ms));
        raw.set("process", number(t.process_ms)); raw.set("convert", number(t.convert_ms));
        raw.set("total", number(t.total_ms));
        raw.set("openmp_enabled", Json(t.openmp_enabled)); raw.set("workers", number(t.workers));
        timings.set("raw", std::move(raw));
    }
    r.set("timings_ms", std::move(timings));
    return r;
}

Json m_open(const Request& q) {
    need_engine();
    const fs::path path = utf8_path(require_string(q.params, "path"));
    const DecodeOptions options = decode_options(q.params.at("decode"));
    Decoded d = decode_frame(path, options);
    std::string delta;
    const Json& params = q.params.at("params");
    if (params.is_object()) delta = params.dump();
    Json opened;
    double open_ms = 0;
    spk_session* handle = engine_open(d.frame, delta, opened, open_ms);

    auto s = std::make_shared<Session>();
    s->handle = handle;
    s->path = path_utf8(path);
    s->width = d.frame.width;
    s->height = d.frame.height;
    s->metadata = d.probe.metadata;
    s->raw_metadata = std::move(d.frame.raw_metadata);
    s->decode = options;
    s->output_space = output_space_of(opened.at("params"));
    {
        std::lock_guard<std::mutex> lock(g.sessions_mutex);
        s->id = "s" + std::to_string(g.next_session++);
        g.sessions[s->id] = s;
    }
    log_line(1, "open " + s->id + " " + s->path + " " + std::to_string(d.frame.width) + "x" +
                    std::to_string(d.frame.height) + " decode " + std::to_string(int(d.decode_ms)) + " ms, open " +
                    std::to_string(int(open_ms)) + " ms");
    return open_reply(*s, d, opened, open_ms);
}


// Hole settings are the persisted pair schema, not the flat host decode wire.
// Translate once, then use the same validation and decoder as an ordinary RAW.
Json pair_decode_wire(const Json& settings) {
    Json wire = Json::object();
    if (settings.has("rawMode")) wire.set("raw_mode", settings.at("rawMode"));
    if (settings.has("lensCorrection")) wire.set("lens_correction", settings.at("lensCorrection"));
    const std::string mode = optional_string(settings, "whiteBalance", "As Shot");
    Json wb = Json::object(); wb.set("mode", str(mode == "As Shot" ? "as_shot" : "custom"));
    if (mode != "As Shot") {
        wb.set("temperature_k", settings.at("temperature")); wb.set("tint", settings.at("tint"));
    }
    wire.set("white_balance", std::move(wb)); return wire;
}
void apply_snapshot(const std::shared_ptr<Session>& s, const Json& p);
Json m_pair(const Request& q, bool updating, bool parent_running = false) {
    need_engine();
    auto s = updating ? find_session(q.params, false) : std::make_shared<Session>();
    if (updating && !s->pair_source) throw HostError{"bad_request", "update_pair requires a pair session"};
    const std::string path = updating ? s->path : require_string(q.params,"path");
    Json recipe = q.params.has("pair") ? q.params.at("pair") : read_pair(utf8_path(path));
    Json params = q.params.at("params");
    if (!params.is_object()) params = Json::object();
    // Exposure is measured/applied per hole. Film compensation still applies
    // to the entire piece in the normal pipeline, including its unexposed gap.
    params.set("auto_exposure", Json(false));
    recipe=PairSource::carry_meter_readings(recipe,params,s->pair);
    const auto signature = PairSource::signature(recipe, params);
    if (updating && signature == s->pair_signature) {
        Json snapshot = Json::object(); snapshot.set("params", params);
        apply_snapshot(s, snapshot);
        s->pair=recipe;
        Json r=Json::object(); r.set("session",str(s->id));r.set("width",number(s->width));r.set("height",number(s->height));
        r.set("kind",str("pair"));r.set("metadata",metadata_json(s->metadata));r.set("pair_info",s->pair_info);
        char* current=nullptr;if(spk_get_params(s->handle,&current)!=SPK_OK)engine_fail(SPK_ERR_INTERNAL,"pair parameters");
        r.set("params",take_json(current));return r;
    }
    std::unique_ptr<Running> running;
    if (!parent_running) running=std::make_unique<Running>(updating?s->id:std::string{},optional_string(q.params,"progress_id"));
    check_cancelled();
    const auto started=Clock::now();
    if(!s->pair_source)s->pair_source=std::make_unique<PairSource>();
    Decoded decoded;PairSource::Description description;std::array<std::optional<double>,2> metered;
    std::string error;
    auto decode=[&](const fs::path& file,const Json& settings,FloatImage& image,Probe& probe,std::string& why) {
        check_cancelled();spk::view::trim_idle_memory(g.engine);
        const auto options=decode_options(pair_decode_wire(settings));
        return decode_linear_prophoto(file,options,image,probe,why);
    };
    auto meter=[&](const FloatImage& image,const std::string& method) {
        Json probe=params;probe.set("auto_exposure",Json(true));probe.set("auto_exposure_method",str(method));
        probe.set("exposure_compensation_ev",number(0));probe.set("overscan_active",Json(false));probe.set("date_imprint_active",Json(false));
        probe.set("film_format_mm",number(24));
        Json opened;double ms=0;spk_session* temporary=engine_open(image,probe.dump(),opened,ms);
        struct Release{spk_session* value;~Release(){spk_session_release(value);}}release{temporary};
        char* text=nullptr;const auto status=spk_solve(temporary,"exposure",&text);
        if(status!=SPK_OK){if(text)spk_string_free(text);engine_fail(status,"pair exposure meter");}
        const auto value=take_json(text).at("solved_params").at("exposure_compensation_ev");
        if(!value.is_number())throw HostError{"engine_error","pair meter returned no exposure"};
        return value.as_double();
    };
    if(!s->pair_source->compose(recipe,params,decoded.frame,description,metered,decode,meter,check_cancelled,error))
        throw HostError{"decode_failed",error};
    decoded.decode_ms=ms_since(started);const size_t first=description.available[0]?0:1;
    decoded.probe.width=decoded.frame.width;decoded.probe.height=decoded.frame.height;decoded.probe.metadata=description.probes[first].metadata;
    decoded.probe.metadata.as_shot_temperature_k.reset();decoded.probe.metadata.as_shot_tint.reset();
    check_cancelled();Json opened;double open_ms=0;spk_session* handle=engine_open(decoded.frame,params.dump(),opened,open_ms);
    spk_session* old=nullptr;
    {
        std::lock_guard<std::mutex> lock(g.sessions_mutex);old=s->handle;s->handle=handle;
        if(!updating){s->id="s"+std::to_string(g.next_session++);g.sessions[s->id]=s;}
    }
    if(old)spk_session_release(old);
    s->path=path;s->width=decoded.frame.width;s->height=decoded.frame.height;s->metadata=decoded.probe.metadata;s->raw_metadata.reset();
    // Canonical source signature includes the actual applied readings now, so
    // receiving these computed fields back from the UI does not redevelop grain.
    for (size_t i=0;i<2;++i) if(metered[i]) {
        const char* side=i?"right":"left";auto hole=recipe.at(side);
        hole.set("meteredEV",number(*metered[i]));hole.set("meteredFor",str(description.meter_keys[i]));recipe.set(side,std::move(hole));
    }
    s->output_space=output_space_of(opened.at("params"));s->pair=recipe;s->pair_signature=PairSource::signature(recipe,params);s->pair_info=pair_info(description,metered);
    s->pair_raw_metadata=description.raw_metadata;s->pair_gains=description.gains;
    Json r=open_reply(*s,decoded,opened,open_ms);r.set("kind",str("pair"));r.set("pair_info",s->pair_info);return r;
}

// R2: decode the session's file again with other decode settings, keeping its
// id and its params. The engine session is replaced (a new source means a new
// negative); on any failure the old one is untouched.
Json m_redecode(const Request& q) {
    auto s = find_session(q.params, false);
    const DecodeOptions options = decode_options(q.params.at("decode"));
    Decoded d = decode_frame(utf8_path(s->path), options);
    char* current = nullptr;
    const spk_status st = spk_get_params(s->handle, &current);
    if (st != SPK_OK) engine_fail(st, "get_params");
    Json params = take_json(current);
    Json opened;
    double open_ms = 0;
    spk_session* handle = engine_open(d.frame, params.dump(), opened, open_ms);
    spk_session* old = nullptr;
    {
        std::lock_guard<std::mutex> lock(g.sessions_mutex);
        old = s->handle;
        s->handle = handle;
    }
    spk_session_release(old);
    s->width = d.frame.width;
    s->height = d.frame.height;
    s->metadata = d.probe.metadata;
    s->raw_metadata = std::move(d.frame.raw_metadata);
    s->decode = options;
    s->output_space = output_space_of(opened.at("params"));
    return open_reply(*s, d, opened, open_ms);
}

Json m_close(const Request& q) {
    std::shared_ptr<Session> s;
    {
        std::lock_guard<std::mutex> lock(g.sessions_mutex);
        const std::string id = q.params.at("session").as_string();
        auto it = g.sessions.find(id);
        if (it == g.sessions.end()) throw HostError{"not_found", "no session '" + id + "'"};
        s = it->second;
        g.sessions.erase(it);
    }
    spk_session_release(s->handle);
    s->handle = nullptr;
    return Json::object();
}

Json m_set_params(const Request& q) {
    auto s = find_session(q.params);
    const Json& delta = q.params.at("delta");
    if (!delta.is_object()) throw HostError{"bad_request", "delta must be an object"};
    char* reply = nullptr;
    const spk_status st = spk_set_params(s->handle, delta.dump().c_str(), &reply);
    if (st != SPK_OK) { if (reply) spk_string_free(reply); engine_fail(st, "set_params"); }
    Json out = take_json(reply);
    s->output_space = output_space_of(out.at("params"));
    Json r = Json::object();
    r.set("params", out.at("params"));
    if (out.has("invalidated")) r.set("invalidated", out.at("invalidated"));
    return r;
}

Json m_get_params(const Request& q) {
    auto s = find_session(q.params, false);
    char* reply = nullptr;
    const spk_status st = spk_get_params(s->handle, &reply);
    if (st != SPK_OK) engine_fail(st, "get_params");
    Json r = Json::object();
    r.set("params", take_json(reply));
    return r;
}

Json view_timings(const spk::view::Result& v, double total) {
    Json t = Json::object();
    t.set("print", number(v.print_ms)); t.set("post", number(v.post_ms));
    t.set("readback", number(v.readback_ms)); t.set("total", number(total));
    return t;
}

spk::view::Request view_request(const Json& p, bool exporting) {
    spk::view::Request r;
    r.tier = exporting ? "full" : optional_string(p, "tier", "live");
    if (r.tier != "live" && r.tier != "preview" && r.tier != "full")
        throw HostError{"bad_request", "tier must be live, preview or full"};
    if (p.has("adjustments") && !p.at("adjustments").is_object()) throw HostError{"bad_request", "adjustments must be an object"};
    if (p.has("geometry") && !p.at("geometry").is_object()) throw HostError{"bad_request", "geometry must be an object"};
    if (p.has("adjustments")) r.adjustments = p.at("adjustments");
    if (p.has("geometry")) r.geometry = p.at("geometry");
    const int edge = p.at("long_edge").as_int(0);
    if (edge < 0 || edge > 65536) throw HostError{"bad_request", "long_edge must be between 0 and 65536"};
    r.long_edge = uint32_t(edge);
    r.target_space = engine_space_name(optional_string(p, exporting ? "color_space" : "display", "srgb"));
    if (r.target_space.empty() || (!exporting && r.target_space != "sRGB" && r.target_space != "Display P3"))
        throw HostError{"bad_request", "unsupported output colour space"};
    r.export_intent = exporting; r.rgba16 = exporting;
    return r;
}

void apply_snapshot(const std::shared_ptr<Session>& s, const Json& p) {
    if (!p.has("params") && !p.has("source_geometry")) return;
    if (p.has("params") && !p.at("params").is_object()) throw HostError{"bad_request", "params must be an object"};
    Json requested = p.has("params") ? p.at("params") : Json::object();
    if (p.has("source_geometry")) {
        const Json& g = p.at("source_geometry");
        if (!g.is_object() || (g.has("crop") && !g.at("crop").is_object()))
            throw HostError{"bad_request", "source_geometry must contain a geometry object"};
        const Json& crop = g.at("crop");
        auto coordinate = [&](const Json& obj, const char* key, double fallback) {
            if (!obj.has(key)) return fallback;
            const auto& v = obj.at(key);
            if (!v.is_number() || !std::isfinite(v.as_double()))
                throw HostError{"bad_request", std::string("invalid source_geometry ") + key};
            return v.as_double();
        };
        requested.set("geometry_crop_x", number(coordinate(crop, "x", 0)));
        requested.set("geometry_crop_y", number(coordinate(crop, "y", 0)));
        requested.set("geometry_crop_w", number(coordinate(crop, "width", 1)));
        requested.set("geometry_crop_h", number(coordinate(crop, "height", 1)));
        requested.set("geometry_rotation_deg", number(coordinate(g, "angle", 0)));
        const double turns = coordinate(g, "quarterTurns", 0);
        if (turns != std::trunc(turns) || turns < -1000 || turns > 1000)
            throw HostError{"bad_request", "invalid source_geometry quarterTurns"};
        requested.set("geometry_quarter_turns", number((int(turns) % 4 + 4) % 4));
        for (const auto& pair : {std::pair{"flipH", "geometry_flip_h"}, std::pair{"flipV", "geometry_flip_v"}}) {
            if (g.has(pair.first) && !g.at(pair.first).is_bool())
                throw HostError{"bad_request", std::string("invalid source_geometry ") + pair.first};
            requested.set(pair.second, Json(g.at(pair.first).as_bool()));
        }
    }
    char* reply = nullptr;
    auto st = spk_get_params(s->handle, &reply);
    if (st != SPK_OK) { if (reply) spk_string_free(reply); engine_fail(st, "read frame snapshot"); }
    const Json current = take_json(reply);
    Json delta = Json::object();
    // A frozen full snapshot is common during export. Resending unchanged
    // stock keys would rebuild the film and regenerate stochastic grain.
    // Unknown keys still reach engine validation instead of being discarded.
    for (const auto& kv : requested.fields())
        if (!current.has(kv.first) || current.at(kv.first).dump() != kv.second.dump())
            delta.set(kv.first, kv.second);
    if (delta.fields().empty()) return;
    reply = nullptr;
    st = spk_set_params(s->handle, delta.dump().c_str(), &reply);
    if (st != SPK_OK) { if (reply) spk_string_free(reply); engine_fail(st, "apply frame snapshot"); }
    s->output_space = output_space_of(take_json(reply).at("params"));
}

Json pair_display_info(const Session& s) {
    Json info=s.pair_info;
    char* reply=nullptr;const auto status=spk_overscan_geometry(s.handle,&reply);
    if(status!=SPK_OK){if(reply)spk_string_free(reply);engine_fail(status,"pair gate layout");}
    const auto layout=take_json(reply);
    if(layout.at("valid").as_bool()&&layout.at("gates").items().size()==2) {
        std::vector<Json> rectangles;
        for(const auto& gate:layout.at("gates").items()) {
            double x0=1,y0=1,x1=0,y1=0;
            for(size_t i=0;i+1<gate.items().size();i+=2){const double x=gate.items()[i].as_double(),y=gate.items()[i+1].as_double();x0=std::min(x0,x);y0=std::min(y0,y);x1=std::max(x1,x);y1=std::max(y1,y);}
            Json r=Json::object();r.set("x",number(x0));r.set("y",number(y0));r.set("width",number(x1-x0));r.set("height",number(y1-y0));rectangles.push_back(std::move(r));
        }
        const char* axis=s.pair.at("turned").as_bool()?"y":"x";
        if(rectangles[1].at(axis).as_double()<rectangles[0].at(axis).as_double())std::swap(rectangles[0],rectangles[1]);
        Json gates=Json::array();for(auto& r:rectangles)gates.push(std::move(r));info.set("gates",std::move(gates));
    }
    return info;
}

void log_node_timings(spk_session* session) {
    if (!std::getenv("SPEKTRAFILM_NODE_TIMINGS")) return;
    char* reply = nullptr;
    if (spk_progress(session, nullptr, &reply) == SPK_OK && reply)
        log_line(1, "detailed engine progress: " + std::string(reply));
    if (reply) spk_string_free(reply);
}

Json m_render_view(const Request& q, std::vector<uint8_t>& payload) {
    const auto started = Clock::now();
    auto s = find_session(q.params);
    auto req = view_request(q.params, false);
    const std::string format = optional_string(q.params, "format", "rgba8");
    if (format != "rgba8" && format != "rgba16") throw HostError{"bad_request", "view format must be rgba8 or rgba16"};
    req.rgba16 = format == "rgba16";
    if (s->pair_source) {
        const auto& recipe = q.params.has("pair") ? q.params.at("pair") : s->pair;
        if (q.params.has("pair") && PairSource::signature(recipe, q.params.at("params"),s->pair) != s->pair_signature)
            throw HostError{"bad_request", "update_pair must install the requested pair source before rendering"};
        req.pair = pair_view_recipe(*s, &recipe);
    }
    Running running(s->id, optional_string(q.params, "progress_id"));
    apply_snapshot(s, q.params);
    spk::view::Result v;
    std::string error;
    if (!spk::view::render(s->handle, req, v, error)) {
        check_cancelled(); throw HostError{"engine_error", error};
    }
    log_node_timings(s->handle);
    check_cancelled();
    Json img = Json::object();
    img.set("width", number(v.width)); img.set("height", number(v.height));
    img.set("source_width", number(v.source_width)); img.set("source_height", number(v.source_height));
    img.set("row_bytes", number(double(v.width) * (req.rgba16 ? 8 : 4))); img.set("format", str(format));
    img.set("color_space", str(req.target_space)); img.set("processed", Json(true));
    img.set("geometry", req.geometry);
    Json r = Json::object(); r.set("image", std::move(img));
    r.set("tier", str(req.tier)); r.set("print_cached", Json(v.print_cached));
    r.set("generation", q.params.at("generation"));
    if (s->pair_source) r.set("pair_info", pair_display_info(*s));
    r.set("timings_ms", view_timings(v, ms_since(started)));
    payload = std::move(v.pixels);
    return r;
}

Json m_render_source(const Request& q, std::vector<uint8_t>& payload) {
    auto s = find_session(q.params);
    const auto req = view_request(q.params, false);
    spk::view::Result v;
    std::string error;
    if (!spk::view::render_source(s->handle, req.long_edge, req.target_space, v, error))
        throw HostError{"engine_error", error};
    Json image = Json::object();
    image.set("width", number(v.width)); image.set("height", number(v.height));
    image.set("row_bytes", number(double(v.width) * 4)); image.set("format", str("rgba8"));
    image.set("color_space", str(req.target_space));
    Json r = Json::object(); r.set("image", std::move(image));
    r.set("generation", q.params.at("generation"));
    r.set("source", str("decoded"));
    payload = std::move(v.pixels); return r;
}

Json m_pick_neutral(const Request& q) {
    auto s = find_session(q.params);
    const Json& x = q.params.at("x"); const Json& y = q.params.at("y");
    if (!x.is_number() || !y.is_number()) throw HostError{"bad_request", "x and y must be normalized source coordinates"};
    const auto* raw=&s->raw_metadata;
    double gain=1;
    if (s->pair_source) {
        const auto side=optional_string(q.params,"side");
        if(side!="left"&&side!="right")throw HostError{"bad_request","pair neutral picking requires left or right side"};
        const size_t i=side=="left"?0:1;
        raw=&s->pair_raw_metadata[i];gain=s->pair_gains[i];
        const auto& gate=s->pair_info.at("gates").items().at(i);
        // The GPU samples a 5x5 source patch. Keep the entire patch in this
        // hole, away from the black film gap and the neighbouring exposure.
        const double px=std::floor(x.as_double()*s->width),py=std::floor(y.as_double()*s->height);
        const double gx=std::round(gate.at("x").as_double()*s->width),gy=std::round(gate.at("y").as_double()*s->height);
        const double gw=std::round(gate.at("width").as_double()*s->width),gh=std::round(gate.at("height").as_double()*s->height);
        if(!std::isfinite(px)||!std::isfinite(py)||px-2<gx||py-2<gy||px+2>=gx+gw||py+2>=gy+gh)
            throw HostError{"bad_request","neutral pick must lie inside the selected pair hole, away from its edge"};
    }
    if (!*raw) throw HostError{"unsupported", "neutral picking requires a RAW source"};
    spk::view::SourceSample sample; std::string error;
    if (!spk::view::sample_source(s->handle, x.as_double(), y.as_double(), sample, error))
        throw HostError{"bad_request", error};
    for(unsigned c=0;c<3;++c){sample.mean[c]/=gain;sample.minimum[c]/=gain;sample.maximum[c]/=gain;}
    if (!(*raw)->headroom_enabled)
        for (unsigned c = 0; c < 3; ++c)
            if (sample.minimum[c] <= .0001 || sample.maximum[c] >= .999)
                throw HostError{"bad_request", "neutral pick: choose an unclipped patch away from deep shadows"};
    double temperature = 0, tint = 0;
    if (!neutral_temperature_tint(**raw, sample.mean, temperature, tint, error))
        throw HostError{"bad_request", error};
    Json r = Json::object(); r.set("temperature_k", number(temperature)); r.set("tint", number(tint));
    return r;
}

Json m_solve(const Request& q) {
    auto s = find_session(q.params);
    std::string target = optional_string(q.params, "target", "both");
    if (s->pair_source) {
        // The pair source already contains each hole's own meter/exposure.
        // Never meter the gap and feed a second global exposure back to it.
        if (target == "exposure") {
            Json result=Json::object();result.set("solved_params",Json::object());result.set("pair_info",s->pair_info);return result;
        }
        if (target == "both") target="filter_pack";
    }
    char* reply = nullptr;
    const spk_status st = spk_solve(s->handle, target.c_str(), &reply);
    if (st != SPK_OK) engine_fail(st, "solve");
    return take_json(reply);
}

std::string tier_of(const Json& params, const char* fallback) {
    const std::string tier = optional_string(params, "tier", fallback);
    if (tier != "live" && tier != "preview" && tier != "full") throw HostError{"bad_request", "tier must be live, preview or full"};
    return tier;
}

Json m_render(const Request& q, std::vector<uint8_t>& payload) {
    auto s = find_session(q.params);
    const std::string tier = tier_of(q.params, "preview");
    const bool want_reprint = q.params.at("reprint").as_bool(false);
    const std::string progress_id = optional_string(q.params, "progress_id");
    Running running(s->id, progress_id);
    progress_event(*s, progress_id, 0.0, "render");
    const auto t0 = Clock::now();
    Result result;
    bool reprinted = false;
    spk_status st = SPK_ERR_USER;
    if (want_reprint) {
        st = spk_reprint(s->handle, tier.c_str(), &result.r);
        reprinted = st == SPK_OK;
        if (st == SPK_ERR_CANCELLED) engine_fail(st, "reprint");
    }
    if (!reprinted) {
        result.r = spk_result{};
        st = spk_render(s->handle, tier.c_str(), &result.r);
        if (st != SPK_OK) engine_fail(st, "render");
    }
    const double render_ms = ms_since(t0);
    progress_event(*s, progress_id, 0.9, "transform");
    const auto t1 = Clock::now();
    Json image;
    package_pixels(result.r, s->output_space, q.params, image, payload);
    Json r = Json::object();
    r.set("image", std::move(image));
    r.set("tier", str(tier));
    r.set("reprinted", Json(reprinted));
    r.set("negative_was_cached", Json(result.r.negative_was_cached != 0));
    r.set("engine_progress_id", str(result.r.progress_id));
    Json timings = Json::object();
    timings.set("engine", number(result.r.elapsed_ms));
    timings.set("render", number(render_ms));
    timings.set("transform", number(ms_since(t1)));
    r.set("timings_ms", std::move(timings));
    progress_event(*s, progress_id, 1.0, "done");
    return r;
}

Json m_scene_latitude(const Request& q) {
    auto s = find_session(q.params);
    apply_snapshot(s, q.params);
    const Json& request = q.params.at("request");
    const std::string text = request.is_object() ? request.dump() : std::string();
    char* reply = nullptr;
    const spk_status st = spk_scene_latitude(s->handle, text.empty() ? nullptr : text.c_str(), &reply);
    if (st != SPK_OK) engine_fail(st, "scene_latitude");
    return take_json(reply);
}

Json m_overscan_geometry(const Request& q) {
    auto s = find_session(q.params, false);
    char* reply = nullptr;
    const spk_status st = spk_overscan_geometry(s->handle, &reply);
    if (st != SPK_OK) engine_fail(st, "overscan_geometry");
    return take_json(reply);
}

std::string lut_output_space(const std::string& stock) {
    Json catalog = parse_json(spk_print_lut_catalog(g.engine));
    const Json& entry = catalog.at(stock);
    if (!entry.is_object()) throw HostError{"not_found", "no print LUT for '" + stock + "'"};
    const std::string space = entry.at("output_color_space").as_string();
    return space.empty() ? "Display P3" : space;
}

Json m_preview_stock_lut(const Request& q, std::vector<uint8_t>& payload) {
    auto s = find_session(q.params);
    const std::string stock = require_string(q.params, "print_stock");
    const std::string tier = tier_of(q.params, "preview");
    const std::string space = lut_output_space(stock);
    Result result;
    char* reply = nullptr;
    const spk_status st = spk_preview_stock_lut(s->handle, stock.c_str(), tier.c_str(), &result.r, &reply);
    if (st != SPK_OK) { if (reply) spk_string_free(reply); engine_fail(st, "preview_stock_lut"); }
    Json info = take_json(reply);
    Json image;
    package_pixels(result.r, space, q.params, image, payload);
    Json r = Json::object();
    r.set("image", std::move(image));
    r.set("lut", std::move(info));
    return r;
}

Json m_progress(const Request& q) {
    auto s = find_session(q.params, false);
    const std::string id = optional_string(q.params, "engine_progress_id");
    char* reply = nullptr;
    const spk_status st = spk_progress(s->handle, id.empty() ? nullptr : id.c_str(), &reply);
    if (st != SPK_OK) engine_fail(st, "progress");
    return take_json(reply);
}

// --- export ---------------------------------------------------------------------

struct Encoded {
    std::vector<uint8_t> bytes;
};

// Linear target RGB -> file bytes in `format`.
void encode_file(const OutputTransform& t, std::vector<float>& lin, uint32_t w, uint32_t h,
                 const std::string& format, int quality, const std::vector<uint8_t>& icc, std::vector<uint8_t>& out,
                 const Exif* exif) {
    std::string error;
    if (format == "tiff16") {
        std::vector<uint16_t> rgba;
        t.encode_rgba16(lin, rgba);
        std::vector<uint16_t> rgb(size_t(w) * h * 3);
        for (size_t p = 0; p < size_t(w) * h; ++p) for (int c = 0; c < 3; ++c) rgb[p * 3 + c] = rgba[p * 4 + c];
        if (!encode_tiff(rgb.data(), w, h, 16, icc, out, error, exif)) throw HostError{"io_error", error};
        return;
    }
    std::vector<uint8_t> rgba;
    t.encode_rgba8(lin, rgba);
    std::vector<uint8_t> rgb(size_t(w) * h * 3);
    for (size_t p = 0; p < size_t(w) * h; ++p) for (int c = 0; c < 3; ++c) rgb[p * 3 + c] = rgba[p * 4 + c];
    bool ok = false;
    if (format == "tiff8") ok = encode_tiff(rgb.data(), w, h, 8, icc, out, error, exif);
    else if (format == "png") ok = encode_png8(rgb.data(), w, h, icc, out, error, exif);
    else if (format == "jpeg") ok = encode_jpeg(rgb.data(), w, h, quality, icc, out, error, exif);
    else throw HostError{"bad_request", "format must be tiff16, tiff8, jpeg or png"};
    if (!ok) throw HostError{"io_error", error};
}

void check_format(const std::string& format) {
    if (format != "tiff16" && format != "tiff8" && format != "jpeg" && format != "png")
        throw HostError{"bad_request", "format must be tiff16, tiff8, jpeg or png"};
}

void shrink_to(std::vector<float>& lin, uint32_t& w, uint32_t& h, uint32_t long_edge) {
    const uint32_t l = std::max(w, h);
    if (!long_edge || l <= long_edge) return;
    const double scale = double(long_edge) / l;
    const uint32_t dw = std::max(1u, uint32_t(std::lround(w * scale)));
    const uint32_t dh = std::max(1u, uint32_t(std::lround(h * scale)));
    std::vector<float> out;
    resize_area(lin.data(), w, h, 3, dw, dh, out);
    lin.swap(out);
    w = dw; h = dh;
}

Json written(const fs::path& path, uint32_t w, uint32_t h, size_t bytes, const std::string& space) {
    Json r = Json::object();
    r.set("path", str(path_utf8(path)));
    r.set("width", number(w));
    r.set("height", number(h));
    r.set("bytes", number(double(bytes)));
    if (!space.empty()) r.set("color_space", str(space));
    return r;
}

// A batch frame can open a private session without changing the editor's
// selection or producing a preview. Its immutable snapshot is the export.
Json m_export_frame(const Request& q, std::vector<uint8_t>* proof_payload = nullptr, bool cineon = false) {
    const auto started = Clock::now();
    if (!q.payload.empty()) throw HostError{"bad_request", "export_frame accepts no image payload"};
    const auto path = proof_payload ? fs::path{} : utf8_path(require_string(q.params, "path"));
    const auto format = optional_string(q.params, "format", "tiff16");
    cineon = cineon || (proof_payload && format == "di");
    if (!cineon) check_format(format);
    const auto compression = optional_string(q.params, "tiff_compression", "none");
    if (compression != "none" && compression != "lzw")
        throw HostError{"bad_request", "tiff_compression must be none or lzw"};
    if (!q.params.at("embed_preview").is_null() && !q.params.at("embed_preview").is_bool())
        throw HostError{"bad_request", "embed_preview must be a boolean"};
    const TiffOptions tiff_options{compression == "lzw", q.params.at("embed_preview").as_bool(false)};
    if (!cineon && format != "tiff8" && format != "tiff16" && (tiff_options.lzw || tiff_options.embed_preview))
        throw HostError{"bad_request", "TIFF options require a TIFF format"};
    Json view_params = q.params;
    if (cineon) { view_params.set("color_space", str("prophoto")); view_params.set("long_edge", number(0)); }
    auto req = view_request(view_params, true);
    req.cineon = cineon;
    req.output_channels = 3;
    req.rgba16 = cineon || format == "tiff16";
    if (proof_payload) {
        const auto& edge = q.params.at("proof_long_edge");
        if (!edge.is_number() || edge.as_double() < 1 || edge.as_double() > 4096 || edge.as_double() != edge.as_int())
            throw HostError{"bad_request", "proof_long_edge must be an integer between 1 and 4096"};
        req.proof_long_edge = uint32_t(edge.as_int());
        req.proof_display = engine_space_name(optional_string(q.params, "display", "srgb"));
        if (req.proof_display != "sRGB" && req.proof_display != "Display P3")
            throw HostError{"bad_request", "proof display must be srgb or display-p3"};
    }
    const bool overwrite = q.params.at("overwrite").as_bool(false);
    std::error_code ec;
    if (!proof_payload && !overwrite && fs::exists(path, ec)) throw HostError{"io_error", "destination exists: " + path_utf8(path)};
    const auto progress = optional_string(q.params, "progress_id");
    Running running(optional_string(q.params, "session"), progress);
    std::shared_ptr<Session> s;
    bool private_session = false;
    std::string source_path;
    if (!optional_string(q.params, "session").empty()) {
        // A different decode snapshot needs a private source. Inspect only
        // metadata first, so an already suspended editor stays on disk.
        s = find_session(q.params, false);
        if (q.params.has("decode")) {
            const auto requested = decode_options(q.params.at("decode"));
            if (requested.raw_mode != s->decode.raw_mode || requested.temperature_k != s->decode.temperature_k ||
                requested.tint != s->decode.tint || requested.lens_correction != s->decode.lens_correction) {
                // A pending UI redecode must not silently export older white balance.
                // Keep the editor's session intact and render the frozen decode privately.
                source_path = s->path;
                s.reset();
            }
        }
        if (s && (s->pair_source || q.params.has("pair"))) {
            if (!q.params.at("pair").is_object()) throw HostError{"bad_request", "pair export requires an immutable pair snapshot"};
            if (!s->pair_source || PairSource::signature(q.params.at("pair"), q.params.at("params"),s->pair) != s->pair_signature) {
                source_path = s->path; s.reset();
            }
        }
    } else source_path = require_string(q.params, "source_path");
    if (!s && pair_path(utf8_path(source_path)) && !q.params.at("pair").is_object())
        throw HostError{"bad_request", "pair export requires an immutable pair snapshot"};
    Json open_timings;
    if (!s) {
        std::vector<std::shared_ptr<Session>> editors;
        {
            std::lock_guard<std::mutex> lock(g.sessions_mutex);
            for (const auto& entry : g.sessions) editors.push_back(entry.second);
        }
        // Preserve the exact random film result. Re-decoding/re-rendering an
        // editor to save memory would change its grain after batch export.
        for (const auto& editor : editors) {
            check_cancelled();
            std::string why;
            if (!spk::view::suspend(editor->handle, why))
                throw HostError{"io_error", "cannot suspend editor cache: " + why};
        }
        spk::view::trim_idle_memory(g.engine);
        check_cancelled();
        Request open = q;
        open.params.set("path", str(source_path));
        const auto opened = q.params.has("pair") ? m_pair(open, false, true) : m_open(open);
        open_timings = opened.at("timings_ms");
        Json identity = Json::object(); identity.set("session", opened.at("session"));
        s = find_session(identity); private_session = true;
    }
    struct ClosePrivate {
        std::shared_ptr<Session> s; bool owned;
        ~ClosePrivate() {
            if (!owned) return;
            std::lock_guard<std::mutex> lock(g.sessions_mutex);
            if (s->handle) spk_session_release(s->handle);
            s->handle = nullptr; g.sessions.erase(s->id);
        }
    } close{s, private_session};
    running.bind(s->id);
    check_cancelled();
    std::string error;
    if (!spk::view::resume(s->handle, error))
        throw HostError{"io_error", "cannot restore editor cache: " + error};
    check_cancelled();
    apply_snapshot(s, q.params);
    if (s->pair_source) {
        if (!s->pair_info.at("left").at("available").as_bool() || !s->pair_info.at("right").at("available").as_bool())
            throw HostError{"bad_request", "fill both half-frame holes with readable photographs before exporting"};
        req.pair = pair_view_recipe(*s, &q.params.at("pair"));
    }
    progress_event(*s, progress, 0, "render");
    if (q.params.has("scene_placement")) {
        const auto& intent = q.params.at("scene_placement");
        if (!intent.is_object()) throw HostError{"bad_request", "scene_placement must be an object"};
        char* text = nullptr;
        const auto status = spk_scene_latitude(s->handle, intent.dump().c_str(), &text);
        if (status != SPK_OK) { if (text) spk_string_free(text); engine_fail(status, "fit export scene placement"); }
        const Json fit = take_json(text).at("fit");
        const Json& delta = fit.at("params_delta");
        if (!fit.at("valid").as_bool() || !delta.is_object())
            throw HostError{"bad_request", "scene placement cannot be fitted to this photograph: " + fit.at("issues").dump()};
        if (!delta.at("scene_latitude_active").is_bool() || !delta.at("scene_latitude_norm").is_string())
            throw HostError{"engine_error", "incomplete scene placement fit"};
        for (const char* key : {"scene_latitude_highlight_knee", "scene_latitude_highlight_room", "scene_latitude_shadow_knee",
                               "scene_latitude_shadow_room", "scene_latitude_rolloff", "scene_latitude_max_lift"})
            if (!delta.at(key).is_number() || !std::isfinite(delta.at(key).as_double()))
                throw HostError{"engine_error", "incomplete scene placement fit"};
        Json fitted = delta;
        if (q.params.has("scene_placement_side")) {
            if (!s->pair_source || optional_string(q.params, "scene_placement_side") != "right")
                throw HostError{"bad_request", "scene_placement_side must be right on a half-frame pair"};
            fitted = Json::object();
            for (const auto& kv : delta.fields()) {
                std::string key = kv.first;
                for (const char* suffix : {"active", "highlight_knee", "highlight_room", "shadow_knee", "shadow_room"})
                    if (key == std::string("scene_latitude_") + suffix) { key = std::string("scene_latitude_b_") + suffix; break; }
                fitted.set(key, kv.second);
            }
        }
        Json snapshot = Json::object(); snapshot.set("params", fitted); apply_snapshot(s, snapshot);
    }
    spk::view::Result v;
    if (!spk::view::render(s->handle, req, v, error)) {
        check_cancelled(); throw HostError{"engine_error", error};
    }
    log_node_timings(s->handle);
    check_cancelled();
    if (proof_payload) {
        Json image = Json::object();
        image.set("width", number(v.width)); image.set("height", number(v.height));
        image.set("row_bytes", number(double(v.width) * 4)); image.set("format", str("rgba8"));
        image.set("color_space", str(req.proof_display));
        Json stats = Json::object();
        const double count = double(v.file_width) * v.file_height;
        stats.set("pixels", number(count));
        stats.set("moved_fraction", number(v.moved_pixels / count));
        stats.set("clipped_fraction", number(v.clipped_pixels / count));
        stats.set("outside_fraction", number(v.outside_pixels / count));
        Json r = Json::object(); r.set("image", std::move(image)); r.set("stats", std::move(stats));
        r.set("file_width", number(v.file_width)); r.set("file_height", number(v.file_height));
        r.set("color_space", str(req.target_space)); r.set("bit_depth", number(req.rgba16 ? 16 : 8));
        r.set("compression_simulated", Json(false)); r.set("print_cached", Json(v.print_cached));
        if (cineon) r.set("encoding", str("cineon"));
        r.set("generation", q.params.at("generation"));
        r.set("timings_ms", view_timings(v, ms_since(started)));
        *proof_payload = std::move(v.pixels);
        return r;
    }
    std::vector<uint8_t> icc;
    if (!icc_for(cineon ? "sRGB" : req.target_space, g.resources, icc, error)) throw HostError{"io_error", error};
    const auto exif = exif_of(s->metadata);
    const auto encode_start = Clock::now();
    const size_t n = size_t(v.width) * v.height;
    if (v.pixels.size() != n * (req.rgba16 ? 6 : 3))
        throw HostError{"internal", "GPU export returned invalid RGB size"};
    Json lut_paths = Json::array();
    if (cineon) {
        if (v.preview_rgb.size() != size_t(v.preview_width) * v.preview_height * 3)
            throw HostError{"internal", "Cineon preview returned invalid RGB size"};
        for (const char* name : {"SpektraLab DI view, Cineon to ProPhoto RGB.cube", "SpektraLab DI view, Cineon to Rec709.cube"}) {
            check_cancelled();
            const auto source = g.resources / "DI" / name, target = path.parent_path() / name;
            std::ifstream input(source, std::ios::binary);
            if (!input) throw HostError{"io_error", "missing DI view LUT: " + path_utf8(source)};
            std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(input)), {});
            if (fs::exists(target, ec)) {
                std::ifstream existing(target, std::ios::binary);
                if (fs::file_size(target, ec) != bytes.size() || ec || !existing ||
                    std::vector<uint8_t>((std::istreambuf_iterator<char>(existing)), {}) != bytes)
                    throw HostError{"io_error", "existing DI view LUT differs; choose another export folder: " + path_utf8(target)};
            } else if (!write_file_atomic(target, bytes, false, error)) throw HostError{"io_error", error};
            lut_paths.push(str(path_utf8(target)));
        }
    }
    progress_event(*s, progress, 0.8, "encode");
    const bool ok = write_file_atomic(path, [&](std::FILE* file, std::string& why) {
        check_cancelled();
        bool encoded = false;
        if (cineon) encoded = encode_cineon_file(file, v.pixels.data(), v.width, v.height,
            v.preview_rgb.data(), v.preview_width, v.preview_height, icc, why, &exif, tiff_options.lzw);
        else if (format == "jpeg") encoded = encode_jpeg_file(file, v.pixels.data(), v.width, v.height,
            q.params.at("quality").as_int(92), icc, why, &exif);
        else if (format == "png") encoded = encode_png8_file(file, v.pixels.data(), v.width, v.height, icc, why, &exif);
        else encoded = encode_tiff_file(file, v.pixels.data(),
            v.width, v.height, format == "tiff16" ? 16 : 8, icc, tiff_options, why, &exif);
        check_cancelled(); // cancellation during compression never commits a partial file
        return encoded;
    }, overwrite, error);
    if (!ok) throw HostError{"io_error", error};
    const auto bytes = fs::file_size(path, ec);
    if (ec) throw HostError{"io_error", "cannot stat written file: " + path_utf8(path)};
    Json r = written(path, v.width, v.height, size_t(bytes), req.target_space);
    auto timings = view_timings(v, ms_since(started));
    timings.set("encode_write", number(ms_since(encode_start)));
    if (private_session) timings.set("source", std::move(open_timings));
    r.set("timings_ms", std::move(timings)); r.set("print_cached", Json(v.print_cached));
    if (q.params.has("generation")) r.set("generation", q.params.at("generation"));
    r.set("exif_copied", Json(true));
    if (cineon) {
        r.set("encoding", str("cineon")); r.set("primaries", str("ProPhoto RGB"));
        r.set("color_space", str("untagged Cineon")); r.set("view_luts", std::move(lut_paths));
    }
    progress_event(*s, progress, 1, "done");
    return r;
}

Json m_export_image(const Request& q) {
    auto s = find_session(q.params);
    const fs::path path = utf8_path(require_string(q.params, "path"));
    const std::string format = optional_string(q.params, "format", "tiff16");
    check_format(format);
    const std::string space = engine_space_name(optional_string(q.params, "color_space", "sRGB"));
    if (space.empty()) throw HostError{"bad_request", "color_space must be sRGB, display-p3 or prophoto"};
    const int quality = q.params.at("quality").as_int(92);
    const uint32_t long_edge = uint32_t(std::max(0, q.params.at("long_edge").as_int(0)));
    const bool overwrite = q.params.at("overwrite").as_bool(false);
    std::error_code ec;
    if (!overwrite && fs::exists(path, ec)) throw HostError{"io_error", "destination exists: " + path_utf8(path)};
    const std::string progress_id = optional_string(q.params, "progress_id");
    Running running(s->id, progress_id);
    progress_event(*s, progress_id, 0.0, "render");
    Result result;
    const spk_status st = spk_render(s->handle, "full", &result.r);
    if (st != SPK_OK) engine_fail(st, "render full");
    progress_event(*s, progress_id, 0.7, "encode");
    const OutputTransform& t = transform(s->output_space, space);
    std::vector<float> lin;
    uint32_t w = result.r.width, h = result.r.height;
    t.to_linear(result.r.rgba16, w, h, result.r.row_stride_px ? result.r.row_stride_px : w, lin);
    shrink_to(lin, w, h, long_edge);
    std::vector<uint8_t> icc, bytes;
    std::string error;
    if (!icc_for(space, g.resources, icc, error)) throw HostError{"io_error", error};
    const Exif exif = exif_of(s->metadata);
    encode_file(t, lin, w, h, format, quality, icc, bytes, &exif);
    if (!write_file_atomic(path, bytes, overwrite, error)) throw HostError{"io_error", error};
    progress_event(*s, progress_id, 1.0, "done");
    return written(path, w, h, bytes.size(), space);
}

// R1: the app renders, applies geometry and Layer 2, and hands the host the
// finished pixels (rgba16 LE, top row first, encoded in `color_space`).
Json m_write_image(const Request& q) {
    const fs::path path = utf8_path(require_string(q.params, "path"));
    const std::string format = optional_string(q.params, "format", "tiff16");
    check_format(format);
    const std::string space = engine_space_name(require_string(q.params, "color_space"));
    if (space.empty()) throw HostError{"bad_request", "color_space must be sRGB, display-p3 or prophoto"};
    const int w = q.params.at("width").as_int(0), h = q.params.at("height").as_int(0);
    if (w <= 0 || h <= 0) throw HostError{"bad_request", "width and height are required"};
    if (q.payload.size() != size_t(w) * size_t(h) * 8)
        throw HostError{"bad_request", "payload must be width*height*8 bytes of rgba16"};
    const bool overwrite = q.params.at("overwrite").as_bool(false);
    const int quality = q.params.at("quality").as_int(92);
    std::vector<uint8_t> icc, bytes;
    std::string error;
    if (!icc_for(space, g.resources, icc, error)) throw HostError{"io_error", error};
    // R1: the shooting data of the photograph the pixels came from.
    std::optional<Exif> exif;
    const std::string source = optional_string(q.params, "source_path");
    if (!source.empty()) {
        Probe probe;
        std::string why;
        if (probe_file(utf8_path(source), probe, why)) exif = exif_of(probe.metadata);
        else log_line(1, "write_image: no EXIF from " + source + ": " + why);
    }
    const Exif* ex = exif ? &*exif : nullptr;
    const size_t pixels = size_t(w) * h;
    auto sample = [&](size_t i) { return uint16_t(q.payload[2 * i] | (q.payload[2 * i + 1] << 8)); };
    bool ok;
    if (format == "tiff16") {
        std::vector<uint16_t> rgb(pixels * 3);
        for (size_t p = 0; p < pixels; ++p) for (int c = 0; c < 3; ++c) rgb[p * 3 + c] = sample(p * 4 + c);
        ok = encode_tiff(rgb.data(), uint32_t(w), uint32_t(h), 16, icc, bytes, error, ex);
    } else {
        std::vector<uint8_t> rgb(pixels * 3);
        for (size_t p = 0; p < pixels; ++p)
            for (int c = 0; c < 3; ++c) rgb[p * 3 + c] = uint8_t((uint32_t(sample(p * 4 + c)) * 255 + 32767) / 65535);
        if (format == "tiff8") ok = encode_tiff(rgb.data(), uint32_t(w), uint32_t(h), 8, icc, bytes, error, ex);
        else if (format == "png") ok = encode_png8(rgb.data(), uint32_t(w), uint32_t(h), icc, bytes, error, ex);
        else ok = encode_jpeg(rgb.data(), uint32_t(w), uint32_t(h), quality, icc, bytes, error, ex);
    }
    if (!ok) throw HostError{"io_error", error};
    if (!write_file_atomic(path, bytes, overwrite, error)) throw HostError{"io_error", error};
    Json r = written(path, uint32_t(w), uint32_t(h), bytes.size(), space);
    r.set("exif_copied", Json(ex != nullptr));
    return r;
}

Json m_export_cube(const Request& q) {
    need_engine();
    const std::string stock = require_string(q.params, "print_stock");
    const fs::path path = utf8_path(require_string(q.params, "path"));
    const float* table = nullptr;
    uint32_t size = 0;
    const spk_status st = spk_print_lut_table(g.engine, stock.c_str(), &table, &size);
    if (st != SPK_OK) engine_fail(st, "print_lut_table");
    const std::string text = cube_text(table, size, "SpektraLab print LUT " + stock);
    std::string error;
    if (!write_file_atomic(path, std::vector<uint8_t>(text.begin(), text.end()), q.params.at("overwrite").as_bool(false), error))
        throw HostError{"io_error", error};
    Json r = Json::object();
    r.set("path", str(path_utf8(path)));
    r.set("size", number(size));
    return r;
}

Json m_export_di(const Request& q) {
    auto s = find_session(q.params);
    const fs::path path = utf8_path(require_string(q.params, "path"));
    const std::string stock = optional_string(q.params, "print_stock");
    Result result;
    char* reply = nullptr;
    const spk_status st = spk_export_di(s->handle, stock.empty() ? nullptr : stock.c_str(), &result.r, &reply);
    if (st != SPK_OK) { if (reply) spk_string_free(reply); engine_fail(st, "export_di"); }
    Json info = take_json(reply);
    const uint32_t w = result.r.width, h = result.r.height, stride = result.r.row_stride_px ? result.r.row_stride_px : w;
    std::vector<uint16_t> rgb(size_t(w) * h * 3);
    for (uint32_t y = 0; y < h; ++y)
        for (uint32_t x = 0; x < w; ++x)
            for (int c = 0; c < 3; ++c) rgb[(size_t(y) * w + x) * 3 + c] = result.r.rgba16[(size_t(y) * stride + x) * 4 + c];
    std::vector<uint8_t> bytes;
    std::string error;
    // Normalised negative density, not a colour space: no ICC profile.
    if (!encode_tiff(rgb.data(), w, h, 16, {}, bytes, error)) throw HostError{"io_error", error};
    if (!write_file_atomic(path, bytes, q.params.at("overwrite").as_bool(false), error)) throw HostError{"io_error", error};
    Json r = written(path, w, h, bytes.size(), "");
    r.set("di", std::move(info));
    return r;
}

void dispatch(const Request& q) {
    std::vector<uint8_t> payload;
    Json result;
    const std::string& m = q.method;
    if (m == "hello") result = m_hello(q);
    else if (m == "params_schema") result = m_params_schema(q);
    else if (m == "print_lut_catalog") result = m_print_lut_catalog(q);
    else if (m == "memory_report") result = m_memory_report(q);
    else if (m == "probe") result = m_probe(q);
    else if (m == "thumbnail") result = m_thumbnail(q, payload);
    else if (m == "open") result = pair_path(utf8_path(q.params.at("path").as_string())) ? m_pair(q, false) : m_open(q);
    else if (m == "open_pair") result = m_pair(q, false);
    else if (m == "update_pair") result = m_pair(q, true);
    else if (m == "close") result = m_close(q);
    else if (m == "redecode") result = m_redecode(q);
    else if (m == "set_params") result = m_set_params(q);
    else if (m == "get_params") result = m_get_params(q);
    else if (m == "solve") result = m_solve(q);
    else if (m == "render") result = m_render(q, payload);
    else if (m == "render_view") result = m_render_view(q, payload);
    else if (m == "render_source") result = m_render_source(q, payload);
    else if (m == "pick_neutral") result = m_pick_neutral(q);
    else if (m == "export_frame") result = m_export_frame(q);
    else if (m == "export_cineon") result = m_export_frame(q, nullptr, true);
    else if (m == "render_proof") result = m_export_frame(q, &payload);
    else if (m == "scene_latitude") result = m_scene_latitude(q);
    else if (m == "overscan_geometry") result = m_overscan_geometry(q);
    else if (m == "preview_stock_lut") result = m_preview_stock_lut(q, payload);
    else if (m == "progress") result = m_progress(q);
    else if (m == "export_image") result = m_export_image(q);
    else if (m == "write_image") result = m_write_image(q);
    else if (m == "export_cube") result = m_export_cube(q);
    else if (m == "export_di") result = m_export_di(q);
    else throw HostError{"unsupported", "unknown method '" + m + "'"};
    respond_ok(q.id, std::move(result), payload.data(), payload.size());
}

// --- threads ---------------------------------------------------------------------

std::mutex g_queue_mutex;
std::condition_variable g_queue_cv;
std::deque<Request> g_queue;
bool g_queue_closed = false;

bool memory_pressure() {
#ifdef _WIN32
    MEMORYSTATUSEX m{};
    m.dwLength = sizeof(m);
    if (!GlobalMemoryStatusEx(&m)) return false;
    constexpr uint64_t reserve = 512ull << 20;
    return m.ullAvailPhys < std::max<uint64_t>(reserve, m.ullTotalPhys / 10) ||
           m.ullAvailPageFile < reserve;
#else
    return false;
#endif
}

void worker() {
    auto last_active = Clock::now();
    bool idle_trimmed = false;
    auto trim_if_idle = [&] {
        if (!idle_trimmed && (Clock::now() - last_active >= std::chrono::seconds(5) || memory_pressure())) {
            const auto freed = spk::view::trim_idle_memory(g.engine);
            log_line(2, "idle memory trim: " + std::to_string(freed) + " device scratch bytes");
            idle_trimmed = true;
        }
    };
    for (;;) {
        Request q;
        {
            std::unique_lock<std::mutex> lock(g_queue_mutex);
            if (!g_queue_cv.wait_for(lock, std::chrono::seconds(1), [] { return g_queue_closed || !g_queue.empty(); })) {
                lock.unlock();
                try { trim_if_idle(); }
                catch (const std::exception& e) { log_line(1, std::string("idle memory trim failed: ") + e.what()); }
                continue;
            }
            if (g_queue.empty()) return;
            q = std::move(g_queue.front());
            g_queue.pop_front();
        }
        const auto t0 = Clock::now();
        try {
            trim_if_idle();
            if (memory_pressure()) spk::view::trim_idle_memory(g.engine);
            dispatch(q);
        } catch (const HostError& e) {
            respond_error(q.id, e.code, e.message);
        } catch (const std::invalid_argument& e) {
            respond_error(q.id, "bad_request", e.what());
        } catch (const std::bad_alloc&) {
            respond_error(q.id, "internal", "out of memory");
        } catch (const std::exception& e) {
            respond_error(q.id, "internal", e.what());
        }
        // Diagnostics polling must not keep a frame-sized pool alive forever.
        const bool metadata_only = q.method == "memory_report" || q.method == "hello" ||
            q.method == "capabilities" || q.method == "params_schema" || q.method == "print_lut_catalog" ||
            q.method == "get_params" || q.method == "progress" || q.method == "overscan_geometry";
        if (!metadata_only) {
            last_active = Clock::now();
            idle_trimmed = false;
        }
        log_line(2, q.method + " #" + std::to_string(q.id) + " " + std::to_string(int(ms_since(t0))) + " ms");
    }
}

void handle_cancel(const Request& q) {
    const std::string session = q.params.at("session").as_string();
    const std::string progress = q.params.at("progress_id").as_string();
    bool running = false;
    {
        std::lock_guard<std::mutex> lock(g.cancel_mutex);
        running = g.running_active &&
            ((!session.empty() && (g.running_session == session || g.running_requested_session == session)) ||
             (session.empty() && !progress.empty())) &&
            (progress.empty() || g.running_progress == progress);
        if (running) g.running_cancelled = true;
        if (!running && !progress.empty()) g.cancelled.insert({session, progress});
        if (running) {
            // Keep the running identity stable until its actual engine session
            // receives cancellation, including exports using a private decode.
            std::lock_guard<std::mutex> sessions_lock(g.sessions_mutex);
            auto it = g.sessions.find(g.running_session);
            if (it != g.sessions.end() && it->second->handle) spk_cancel(it->second->handle, nullptr);
        }
    }
    Json r = Json::object();
    r.set("was_running", Json(running));
    respond_ok(q.id, std::move(r));
}

[[noreturn]] void quit(int code) {
    std::fflush(stdout);
    std::fflush(stderr);
    // The worker may be inside a render; the GPU driver and the OS reclaim
    // everything. Destroying the engine under a live render would race it.
    std::_Exit(code);
}

void reader() {
    for (;;) {
        uint8_t prefix[8];
        if (!read_exact(prefix, 8)) { log_line(1, "stdin closed; exiting"); quit(0); }
        uint32_t h = 0, p = 0;
        for (int i = 0; i < 4; ++i) { h |= uint32_t(prefix[i]) << (8 * i); p |= uint32_t(prefix[4 + i]) << (8 * i); }
        if (h > kMaxHeader) { log_line(0, "header length " + std::to_string(h) + " exceeds bound; exiting"); quit(2); }
        std::string text(h, '\0');
        Request q;
        q.payload.resize(p);
        if (!read_exact(text.data(), h) || (p && !read_exact(q.payload.data(), p))) {
            log_line(0, "stdin closed inside a frame; exiting");
            quit(2);
        }
        Json header;
        std::string error;
        if (!Json::parse(text, header, error) || !header.is_object()) {
            log_line(0, "unparsable request header: " + error);
            continue;
        }
        q.id = uint32_t(header.at("id").as_double(0));
        q.method = header.at("method").as_string();
        if (header.at("params").is_object()) q.params = header.at("params");
        if (q.method.empty()) { respond_error(q.id, "bad_request", "missing method"); continue; }
        if (q.method == "ping") { respond_ok(q.id, Json::object()); continue; }
        if (q.method == "cancel") {
            try { handle_cancel(q); } catch (const std::exception& e) { respond_error(q.id, "internal", e.what()); }
            continue;
        }
        if (q.method == "shutdown") {
            respond_ok(q.id, Json::object());
            log_line(1, "shutdown requested");
            quit(0);
        }
        {
            std::lock_guard<std::mutex> lock(g_queue_mutex);
            g_queue.push_back(std::move(q));
        }
        g_queue_cv.notify_one();
    }
}

void usage() {
    std::fprintf(stderr,
                 "usage: spektralab-host --resources <engine-resources-dir> [--device <index>] "
                 "[--log-level error|info|debug]\n"
                 "Speaks desktop/HOST-PROTOCOL.md on stdin/stdout.\n");
}

}  // namespace

int main(int argc, char** argv) {
    set_binary_stdio();
    const std::vector<std::string> args = utf8_args(argc, argv);
    std::string resources;
    for (size_t i = 1; i < args.size(); ++i) {
        const std::string& a = args[i];
        const bool has_value = i + 1 < args.size();
        if (a == "--resources" && has_value) resources = args[++i];
        else if (a == "--device" && has_value) set_env("SPEKTRAFILM_VULKAN_DEVICE", args[++i]);
        else if (a == "--log-level" && has_value) {
            const std::string& v = args[++i];
            g_log_level = v == "error" ? 0 : v == "debug" ? 2 : 1;
        } else if (a == "--version") {
            std::printf("spektralab-host %s (%s)\n", SPEKTRALAB_HOST_VERSION, spk_build_info());
            return 0;
        } else if (a == "--help" || a == "-h") {
            usage();
            return 0;
        } else {
            usage();
            return 2;
        }
    }
    // Default: beside the executable, as build/host-<os>-x64/ stages it.
    if (resources.empty()) resources = path_utf8(executable_dir(argv[0]) / "engine");
    g.resources = utf8_path(resources);
    lens_database(g.resources / "lensfun" / "version_2");
    const auto t0 = Clock::now();
    g.engine = spk_engine_create(resources.c_str(), nullptr);
    if (!g.engine) {
        g.engine_error = spk_last_error(nullptr);
        log_line(0, "engine did not start: " + g.engine_error);
    } else {
        Json caps = parse_json(spk_capabilities(g.engine));
        log_line(1, "engine up in " + std::to_string(int(ms_since(t0))) + " ms on " +
                        caps.at("backend").at("gpu").as_string() + " (" +
                        caps.at("backend").at("math_mode").as_string() + ")");
    }
    std::thread work(worker);
    reader();   // never returns: exits through quit()
    work.join();
    return 0;
}
