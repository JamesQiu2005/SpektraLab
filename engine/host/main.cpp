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

#include "image_io.hpp"
#include "cineon_view.hpp"
#include "pair_composer.hpp"
#include "pair_cache.hpp"
#include "json.hpp"
#include "output.hpp"
#include "platform.hpp"
#include "spektrafilm/spk_engine.h"

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
    std::string output_space = "ProPhoto RGB";
    Json params;
    bool cineon = false;
    Json pair_info;
    bool pair_client_presentation=false;
};

struct State {
    fs::path resources;
    spk_engine* engine = nullptr;
    std::string engine_error;
    std::map<std::string, std::shared_ptr<Session>> sessions;
    std::mutex sessions_mutex;   // the reader thread reads `sessions` for cancel
    uint64_t next_session = 1;
    std::map<std::string, OutputTransform> transforms;
    CineonView cineon_view;
    std::string cineon_error;
    std::map<std::string, bool> positive_films;

    // cancellation
    std::mutex cancel_mutex;
    std::string running_session, running_progress;
    std::set<std::pair<std::string, std::string>> cancelled;   // (session, progress_id) not yet started
} g;

std::shared_ptr<Session> find_session(const Json& params) {
    const std::string id = params.at("session").as_string();
    std::lock_guard<std::mutex> lock(g.sessions_mutex);
    auto it = g.sessions.find(id);
    if (it == g.sessions.end()) throw HostError{"not_found", "no session '" + id + "'"};
    return it->second;
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
    if (m.focal_35mm) j.set("focal_35mm", number(*m.focal_35mm));
    if (m.exposure_program) j.set("exposure_program", number(*m.exposure_program));
    if (m.exposure_bias_ev) j.set("exposure_bias_ev", number(*m.exposure_bias_ev));
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
    e.focal_35mm = m.focal_35mm;
    e.exposure_program = m.exposure_program;
    e.exposure_bias_ev = m.exposure_bias_ev;
    return e;
}

std::string output_space_of(const Json& params) {
    const Json& nested = params.path("io.output_color_space");
    if (nested.is_string()) return nested.as_string();
    const Json& flat = params.at("output_color_space");
    if (flat.is_string()) return flat.as_string();
    return "ProPhoto RGB";
}

bool positive_film(const std::string& stock) {
    auto it = g.positive_films.find(stock);
    if (it == g.positive_films.end()) {
        // Read only the original profile's polarity metadata. No material
        // values or rendering arithmetic live in this presentation decision.
        std::vector<uint8_t> bytes;
        std::string error;
        if (!read_file(g.resources / "profiles" / utf8_path(stock + ".json"), bytes, error))
            throw HostError{"io_error", error};
        const Json profile = parse_json(std::string(bytes.begin(), bytes.end()).c_str());
        it = g.positive_films.emplace(stock, profile.at("info").at("type").as_string() == "positive").first;
    }
    return it->second;
}

void check_cineon_request(const Json& params) {
    if (!params.at("digital_intermediate").as_bool() || params.at("scan_film").as_bool()) return;
    if (!g.cineon_view.ready()) throw HostError{"unsupported", "Cineon DI view resources: " + g.cineon_error};
    if (output_space_of(params) != "ProPhoto RGB")
        throw HostError{"bad_request", "the shipped Cineon DI view requires ProPhoto RGB output primaries"};
    const auto& stock = params.at("film_stock").as_string();
    if (!stock.empty()) positive_film(stock); // preflight metadata before set_params commits
}

void remember_params(Session& session, const Json& params) {
    const bool cineon = params.at("digital_intermediate").as_bool() && !params.at("scan_film").as_bool() &&
                        !positive_film(params.at("film_stock").as_string());
    session.params = params;
    session.output_space = output_space_of(params);
    session.cineon = cineon;
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
                    std::vector<uint8_t>& payload, bool cineon = false) {
    if (cineon) {
        std::vector<uint16_t> viewed;
        g.cineon_view.apply(r.rgba16, r.width, r.height, r.row_stride_px ? r.row_stride_px : r.width, viewed);
        spk_result view = r;
        view.rgba16 = viewed.data();
        view.row_stride_px = view.width;
        package_pixels(view, "ProPhoto RGB", params, image, payload);
        return;
    }
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
        if (!progress.empty() && g.cancelled.erase({session, progress}))
            throw HostError{"cancelled", "cancelled before it started"};
        g.running_session = session;
        g.running_progress = progress;
    }
    ~Running() {
        std::lock_guard<std::mutex> lock(g.cancel_mutex);
        g.running_session.clear();
        g.running_progress.clear();
    }
};

// --- methods -------------------------------------------------------------------

Json m_hello(const Request&) {
    Json r = Json::object();
    r.set("protocol", number(kProtocol));
    r.set("host_version", str(SPEKTRALAB_HOST_VERSION));
    r.set("build_info", str(spk_build_info()));
    r.set("resources_dir", str(path_utf8(g.resources)));
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
    Json host_caps = b;
    Json unsupported = b.at("unsupported_features");
    if (!unsupported.is_array()) unsupported = Json::array();
    if (!g.cineon_view.ready()) unsupported.push(str("digital_intermediate"));
    host_caps.set("unsupported_features", std::move(unsupported));
    host_caps.set("pair_decode",Json(true));
    host_caps.set("pair_presentation",str("client-layers-v1"));
    caps.set("backend", std::move(host_caps));
    r.set("backend", std::move(backend));
    r.set("capabilities", std::move(caps));
    Json methods = Json::array();
    for (const char* m : {"hello", "ping", "shutdown", "params_schema", "print_lut_catalog", "memory_report",
                          "probe", "thumbnail", "open", "redecode", "close", "set_params", "get_params", "solve", "render",
                          "scene_latitude", "overscan_geometry", "pair_info", "render_layer", "preview_stock_lut", "cancel", "progress",
                          "export_image", "export_cube", "export_di", "export_cineon", "write_image"})
        methods.push(str(m));
    r.set("methods", std::move(methods));
    return r;
}

Json m_params_schema(const Request&) { need_engine(); return parse_json(spk_params_schema(g.engine)); }
Json m_print_lut_catalog(const Request&) { need_engine(); return parse_json(spk_print_lut_catalog(g.engine)); }
spkhost::pair::HoleCache pair_bitmaps; // used only by the host worker
Json m_memory_report(const Request&) {
    need_engine();auto report=parse_json(spk_memory_report(g.engine));
    Json cache=Json::object();cache.set("entries",number(pair_bitmaps.size()));cache.set("bytes",number(pair_bitmaps.memory()));
    cache.set("limit_bytes",number(spkhost::pair::HoleCache::limit));report.set("pair_bitmap_cache",std::move(cache));return report;
}

bool is_pair_path(const fs::path& path);
Json probe_pair(const fs::path& path);
Json thumbnail_pair(const fs::path& path,uint32_t edge,std::vector<uint8_t>& payload);

Json m_probe(const Request& q) {
    Probe p;
    std::string error;
    const fs::path path = utf8_path(require_string(q.params, "path"));
    if(is_pair_path(path)) return probe_pair(path);
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
    if(is_pair_path(path)) return thumbnail_pair(path,long_edge,payload);
    Rgba8 t;
    std::string source, error;
    std::error_code ec;
    if (!fs::exists(path, ec)) throw HostError{"not_found", "not found: " + path_utf8(path)};
    if (!thumbnail(path, long_edge, t, source, error)) throw HostError{"decode_failed", error};
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
            // LibRaw carries no lens profiles (Core Image reads the maker's
            // own correction data; nothing portable here does).
            if (kv.second.as_bool(false))
                throw HostError{"unsupported", "lens correction at decode is not available in this host"};
        } else {
            throw HostError{"unsupported", "decode." + kv.first + " is not supported by this host"};
        }
    }
    return options;
}

struct PairDecoded {
    Json document;
    std::array<spkhost::pair::Source,2> sources;
    spkhost::pair::Layout layout;
    bool strip = false;
};

struct Decoded {
    FloatImage frame;
    Probe probe;
    double decode_ms = 0;
    std::shared_ptr<PairDecoded> pair;
};

Decoded decode_single_frame(const fs::path& path, const DecodeOptions& options) {
    std::error_code ec;
    if (!fs::exists(path, ec)) throw HostError{"not_found", "not found: " + path_utf8(path)};
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

bool is_pair_path(const fs::path& path) { return path.extension() == ".spektrapair"; }

// Cache identity is deliberately about input pixels, never a film/paper look.
std::string pair_source_key(const fs::path& source,const Json& decode) {
    std::error_code ec;const auto path=fs::weakly_canonical(source,ec);if(ec)return {};
    const auto size=fs::file_size(path,ec);if(ec)return {};
    const auto stamp=fs::last_write_time(path,ec);if(ec)return {};
    Json key=Json::object();key.set("path",str(path_utf8(path)));key.set("size",str(std::to_string(size)));
    key.set("stamp",str(std::to_string(stamp.time_since_epoch().count())));key.set("decode",decode);return key.dump();
}

std::string pair_bitmap_key(const spkhost::pair::Source& source,const spkhost::pair::Layout& layout) {
    if(source.cache_source.empty())return {};
    Json key=Json::object();key.set("source",str(source.cache_source));
    key.set("geometry",source.settings.at("geometry"));key.set("placement",source.settings.at("placement"));
    key.set("width",number(layout.hole.w));key.set("height",number(layout.hole.h));key.set("turned",Json(layout.turned));return key.dump();
}

Decoded decode_frame(const fs::path& path, const DecodeOptions& options, const Json& params = Json(),bool probe_only=false,uint32_t thumbnail_edge=0,bool client_presentation=false) {
    if (!is_pair_path(path)) return decode_single_frame(path, options);
    if(options.temperature_k || options.tint || options.raw_mode!="compatible16")
        throw HostError{"unsupported","pair white balance/raw-mode belongs to each source hole"};
    const auto started=Clock::now();
    std::vector<uint8_t> bytes; std::string error; Json doc;
    std::error_code file_error;
    if(fs::file_size(path,file_error)>1024*1024 && !file_error) throw HostError{"bad_request","half-frame pair JSON exceeds 1 MiB"};
    if (!read_file(path,bytes,error)) throw HostError{"not_found",error};
    if (bytes.size()>1024*1024 || !Json::parse(std::string(bytes.begin(),bytes.end()),doc,error) || !doc.is_object())
        throw HostError{"bad_request","invalid half-frame pair JSON: "+error};
    if(!doc.at("folder").is_string()) throw HostError{"bad_request","half-frame pair needs its folder"};
    if (!doc.at("schemaVersion").is_null() && doc.at("schemaVersion").as_double()!=1)
        throw HostError{"unsupported","unsupported half-frame pair schema"};
    for(const char* k:{"onStrip","turned"}) if(!doc.at(k).is_null() && !doc.at(k).is_bool())
        throw HostError{"bad_request",std::string("invalid pair boolean: ")+k};
    if(params.has("overscan_active") && !params.at("overscan_active").is_bool()) throw HostError{"bad_request","overscan_active must be boolean"};
    Decoded out;
    out.pair=std::make_shared<PairDecoded>();
    auto& p=*out.pair; p.document=doc;
    p.strip=params.has("overscan_active")?params.at("overscan_active").as_bool():doc.at("onStrip").as_bool();
    for (size_t i=0;i<2;++i) {
        auto& s=p.sources[i]; s.settings=doc.at(i==0?"left":"right");
        if(s.settings.is_null()) continue;
        if(!s.settings.is_object() || !s.settings.at("path").is_string() || s.settings.at("path").as_string().empty()) throw HostError{"bad_request","a pair hole needs a source path"};
        if(!s.settings.at("autoExposure").is_null() && !s.settings.at("autoExposure").is_bool()) throw HostError{"bad_request","pair autoExposure must be boolean"};
        // Do not silently discard edits whose presentation stage is not ported.
        if(!client_presentation && !probe_only && !thumbnail_edge && (!s.settings.at("print").is_null() || !s.settings.at("adjustments").is_null()))
            throw HostError{"unsupported","per-hole print/Post-Dev edits are not available in the pair host yet"};
        try {
            s.geometry=spkhost::pair::geometry(s.settings.at("geometry"));
            s.placement=spkhost::pair::placement(s.settings.at("placement"));
            s.exposure=spkhost::pair::numeric(s.settings,"exposureEV",0);
            if(std::abs(s.exposure)>32) throw std::runtime_error("pair exposure outside -32..32 stops");
        } catch(const std::exception& e) { throw HostError{"bad_request",e.what()}; }
        fs::path source=utf8_path(s.settings.at("path").as_string());
        if(source.is_relative()) source=path.parent_path()/source;
        s.path=source;
        if(is_pair_path(source)) throw HostError{"bad_request","a pair hole must reference a photograph, not another pair"};
        const auto& decode=s.settings.at("decode");
        if(!decode.is_null() && !decode.is_object()) throw HostError{"bad_request","invalid pair source decode"};
        if(decode.at("lensCorrection").as_bool()) throw HostError{"unsupported","pair source lens correction is unavailable in this host"};
        DecodeOptions own;
        const std::string wb=optional_string(decode,"whiteBalance","As Shot");
        if(wb!="As Shot") {
            const std::map<std::string,double> presets{{"Daylight",5500},{"Cloudy",6500},{"Shade",7500},{"Tungsten",3200},{"Fluorescent",4000},{"Custom",5500}};
            const auto preset=presets.find(wb);
            if(preset==presets.end()) throw HostError{"bad_request","unknown pair source white balance"};
            double temperature=0,tint=0;
            try { temperature=spkhost::pair::numeric(decode,"temperature",preset->second); tint=spkhost::pair::numeric(decode,"tint",0); }
            catch(const std::exception& e) { throw HostError{"bad_request",e.what()}; }
            if(temperature<2000 || temperature>50000 || tint<-150 || tint>150) throw HostError{"bad_request","pair source white balance out of range"};
            own.temperature_k=temperature; own.tint=tint;
        }
        try {
            if(probe_only) {
                Probe probe; std::string why;
                if(!probe_file(source,probe,why)) throw HostError{"decode_failed",why};
                s.pixels.width=probe.width; s.pixels.height=probe.height; s.metadata=std::move(probe.metadata);
            } else if(thumbnail_edge) {
                Rgba8 image; std::string origin,why;
                if(!thumbnail(source,std::min(8192u,thumbnail_edge*2),image,origin,why)) throw HostError{"decode_failed",why};
                s.pixels.width=image.width; s.pixels.height=image.height; s.pixels.rgb.resize(size_t(image.width)*image.height*3);
                for(size_t j=0;j<size_t(image.width)*image.height;++j) for(size_t c=0;c<3;++c) s.pixels.rgb[j*3+c]=image.rgba[j*4+c]/255.f;
            } else {
                s.decode_options=own;s.cache_source=pair_source_key(source,decode);
                // A cached hole also knows the exact decoder-native size. It
                // supplies layout without retaining a full demosaiced RAW.
                if(!pair_bitmaps.source(s.cache_source,s)) {
                    auto d=decode_single_frame(source,own);
                    s.pixels=std::move(d.frame); s.metadata=std::move(d.probe.metadata);
                }
            }
        } catch(const HostError& e) {
            if(e.code=="unsupported") throw;
            s.error=e.message; // missing/corrupt photograph is unexposed film
        }
    }
    try {
        const double spacing=p.strip?1.:std::clamp(spkhost::pair::numeric(doc,"spacingMM",1),.5,2.);
        p.layout=spkhost::pair::layout(p.sources,spacing,doc.at("turned").as_bool());
        if(thumbnail_edge && std::max(p.layout.size.w,p.layout.size.h)>thumbnail_edge) {
            const double k=double(thumbnail_edge)/std::max(p.layout.size.w,p.layout.size.h);
            const uint32_t across=uint32_t(std::floor((p.layout.turned?p.layout.hole.w:p.layout.hole.h)*k));
            p.layout=spkhost::pair::make_layout(across,spacing,p.layout.turned);
        }
        // Pin both available hits before a miss is inserted: a large hole
        // must not evict the other hole just before we ask for that picture.
        if(!probe_only&&!thumbnail_edge) for(auto& s:p.sources) if(s.pixels.width) {
            if(pair_bitmaps.get(pair_bitmap_key(s,p.layout),s.hole)){s.bitmap_reused=true;s.pixels={};}
        }
        if(!probe_only) for(auto& s:p.sources) {
            if(!s.pixels.width)continue;
            if(thumbnail_edge){spkhost::pair::sample_hole(s,p.layout);continue;}
            const auto key=pair_bitmap_key(s,p.layout);
            if(s.pixels.rgb.empty()) {
                try {
                    auto d=decode_single_frame(s.path,s.decode_options);
                    s.pixels=std::move(d.frame);s.metadata=std::move(d.probe.metadata);
                } catch(const HostError& e) {
                    if(e.code=="unsupported")throw;
                    s.error=e.message;s.pixels={};continue;
                }
            }
            const spkhost::pair::Size native{s.pixels.width,s.pixels.height};
            spkhost::pair::sample_hole(s,p.layout);
            try {pair_bitmaps.keep(s.cache_source,key,native,s.metadata,s.hole);}
            catch(const std::bad_alloc&) {/* Cache allocation is optional; the sampled hole is valid. */}
        }
    } catch(const std::exception& e) { throw HostError{"bad_request",e.what()}; }
    for(const auto& s:p.sources) if(s.present()) { out.probe.metadata=s.metadata; break; }
    out.probe.metadata.orientation=1;
    out.probe.width=p.layout.size.w; out.probe.height=p.layout.size.h;
    out.decode_ms=ms_since(started);
    return out;
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

Json pair_info(const PairDecoded& p) {
    Json info=Json::object(), sources=Json::array(), rects=Json::array();
    bool complete=true;
    for(size_t i=0;i<2;++i) {
        const auto& s=p.sources[i]; Json shot=Json::object();
        shot.set("path",s.settings.at("path")); shot.set("present",Json(s.present()));
        shot.set("metadata",metadata_json(s.metadata)); shot.set("decode_error",str(s.error));
        shot.set("exposure_ev",number(s.exposure)); shot.set("metered_ev",number(s.metered));
        if(!s.metered_for.empty()) shot.set("metered_for",str(s.metered_for));
        shot.set("meter_reused",Json(s.meter_reused));
        shot.set("bitmap_reused",Json(s.bitmap_reused));
        sources.push(std::move(shot)); complete=complete&&s.present();
        const auto r=p.layout.rect(i); Json rect=Json::array();
        for(double v:{r.x/p.layout.size.w,r.y/p.layout.size.h,r.w/p.layout.size.w,r.h/p.layout.size.h}) rect.push(number(v));
        rects.push(std::move(rect));
    }
    info.set("complete",Json(complete)); info.set("can_export",Json(complete));
    info.set("turned",Json(p.layout.turned)); info.set("on_strip",Json(p.strip));
    info.set("sources",std::move(sources)); info.set("rects",std::move(rects));
    return info;
}

Json probe_pair(const fs::path& path) {
    auto d=decode_frame(path,DecodeOptions{},Json(),true);
    Json r=Json::object(); r.set("kind",str("pair"));
    r.set("width",number(d.probe.width)); r.set("height",number(d.probe.height));
    r.set("metadata",metadata_json(d.probe.metadata)); r.set("pair",pair_info(*d.pair));
    return r;
}

Json thumbnail_pair(const fs::path& path,uint32_t edge,std::vector<uint8_t>& payload) {
    // Camera/embedded previews, framed like the linear decode. Never a film
    // simulation or a predeveloped image standing in for the engine input.
    edge=std::min(edge,4096u);
    auto d=decode_frame(path,DecodeOptions{},Json(),false,edge);
    auto image=spkhost::pair::compose(d.pair->sources,d.pair->layout,false);
    uint32_t w=image.width,h=image.height;
    if(std::max(w,h)>edge) {
        const double k=double(edge)/std::max(w,h);
        const uint32_t nw=std::max(1u,uint32_t(std::lround(w*k))),nh=std::max(1u,uint32_t(std::lround(h*k)));
        std::vector<float> small; resize_area(image.rgb.data(),w,h,3,nw,nh,small);
        image.rgb=std::move(small); w=nw; h=nh;
    }
    payload.resize(size_t(w)*h*4);
    for(size_t i=0;i<size_t(w)*h;++i) {
        for(size_t c=0;c<3;++c) payload[i*4+c]=uint8_t(std::lround(std::clamp(image.rgb[i*3+c],0.f,1.f)*255));
        payload[i*4+3]=255;
    }
    Json info=Json::object(); info.set("width",number(w)); info.set("height",number(h));
    info.set("row_bytes",number(double(w)*4)); info.set("format",str("rgba8")); info.set("color_space",str("sRGB"));
    Json r=Json::object(); r.set("image",std::move(info)); r.set("source",str("pair-source-preview"));
    r.set("orientation_applied",Json(true)); return r;
}

// As on the Mac: intent, owner crop and decode identify a reading. Moving,
// zooming, turning the piece, exposure trims and print edits must not pump it.
// Add a version/file fingerprint so stale files or foreign decoder readings
// are never silently reused. The frontend persists these opaque keys in the
// recipe; the host remains a read-only consumer of user files.
std::string pair_meter_key(const spkhost::pair::Source& s,const Json& params) {
    std::error_code ec;
    const auto path=fs::weakly_canonical(s.path,ec); if(ec)return {};
    const auto size=fs::file_size(path,ec); if(ec)return {};
    const auto stamp=fs::last_write_time(path,ec); if(ec)return {};
    Json key=Json::object();
    key.set("source",str(path_utf8(path)));key.set("size",str(std::to_string(size)));
    key.set("stamp",str(std::to_string(stamp.time_since_epoch().count())));
    key.set("decode",s.settings.at("decode"));
    key.set("method",str(optional_string(s.settings,"meterMethod",optional_string(params,"auto_exposure_method","center_weighted"))));
    Json crop=Json::array();for(double v:{s.geometry.crop.x,s.geometry.crop.y,s.geometry.crop.w,s.geometry.crop.h})crop.push(number(v));
    key.set("crop",std::move(crop));key.set("turns",number(s.geometry.turns));
    return "windows-pair-meter-v1:"+key.dump();
}

void prepare_pair(Decoded& d,Json& params) {
    if(!d.pair) return;
    auto& p=*d.pair;
    params.set("auto_exposure",Json(false));
    params.set("overscan_pair",Json(true)); params.set("overscan_format",str("135_half"));
    params.set("overscan_active",Json(p.strip));
    if(!params.has("film_format_mm")) params.set("film_format_mm",number(36+(p.strip?1.:std::clamp(spkhost::pair::numeric(p.document,"spacingMM",1),.5,2.))));
    params.set("scene_latitude_split",number(.5));
    for(auto& s:p.sources) if(s.present() && s.settings.at("autoExposure").as_bool(true)) {
        s.metered_for=pair_meter_key(s,params);
        const auto& kept=s.settings.at("meteredEV");
        if(!s.metered_for.empty() && s.settings.at("meteredFor").is_string() && s.settings.at("meteredFor").as_string()==s.metered_for &&
           kept.is_number() && std::isfinite(kept.as_double()) && std::abs(kept.as_double())<=64) {
            s.metered=kept.as_double();s.meter_reused=true;continue;
        }
        Json meter=params;
        meter.set("auto_exposure",Json(true)); meter.set("exposure_compensation_ev",number(0));
        meter.set("overscan_active",Json(false)); meter.set("overscan_pair",Json(false));
        meter.set("date_imprint_active",Json(false)); meter.set("scene_latitude_split",number(0));
        meter.set("film_format_mm",number(24));
        if(s.settings.at("meterMethod").is_string()) meter.set("auto_exposure_method",s.settings.at("meterMethod"));
        for(const char* k:{"geometry_crop_x","geometry_crop_y","geometry_rotation_deg","geometry_quarter_turns"}) meter.set(k,number(0));
        for(const char* k:{"geometry_crop_w","geometry_crop_h"}) meter.set(k,number(1));
        meter.set("geometry_flip_h",Json(false)); meter.set("geometry_flip_v",Json(false));
        Json opened; double ms=0;
        spk_session* alone=engine_open(s.hole,meter.dump(),opened,ms);
        char* solved=nullptr;
        const auto st=spk_solve(alone,"exposure",&solved);
        spk_session_release(alone);
        if(st!=SPK_OK) { if(solved) spk_string_free(solved); engine_fail(st,"pair source meter"); }
        const auto result=take_json(solved);
        const auto& ev=result.at("solved_params").at("exposure_compensation_ev");
        if(!ev.is_number() || !std::isfinite(ev.as_double())) throw HostError{"engine_error","pair source meter returned no finite exposure"};
        s.metered=ev.as_double();
    }
    try { d.frame=spkhost::pair::compose(p.sources,p.layout); }
    catch(const std::exception& e) { throw HostError{"bad_request",e.what()}; }
}

Json open_reply(const Session& s, const Decoded& d, const Json& opened, double open_ms) {
    Json r = Json::object();
    r.set("session", str(s.id));
    r.set("width", number(d.frame.width));
    r.set("height", number(d.frame.height));
    r.set("kind", str(d.pair?"pair":kind_name(d.probe.kind)));
    if(d.pair) r.set("pair",pair_info(*d.pair));
    r.set("metadata", metadata_json(d.probe.metadata));
    r.set("params", opened.at("params"));
    r.set("detected_input", opened.at("detected_input"));
    r.set("output_color_space", str(s.output_space));
    Json timings = Json::object();
    timings.set("decode", number(d.decode_ms));
    timings.set("open", number(open_ms));
    r.set("timings_ms", std::move(timings));
    return r;
}

Json m_open(const Request& q) {
    need_engine();
    const fs::path path = utf8_path(require_string(q.params, "path"));
    const DecodeOptions options = decode_options(q.params.at("decode"));
    Json params=q.params.at("params");
    if(params.is_null()) params=Json::object();
    if(!params.is_object()) throw HostError{"bad_request","open.params must be an object"};
    const bool presentation=q.params.at("pair_presentation").as_string()=="client";
    if(!q.params.at("pair_presentation").is_null()&&!presentation) throw HostError{"bad_request","pair_presentation must be client"};
    Decoded d = decode_frame(path, options,params,false,0,presentation);
    prepare_pair(d,params);
    std::string delta;
    check_cineon_request(params);
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
    s->pair_client_presentation=d.pair&&presentation;
    if(d.pair) s->pair_info=pair_info(*d.pair);
    try { remember_params(*s, opened.at("params")); }
    catch (...) { spk_session_release(handle); s->handle = nullptr; throw; }
    {
        std::lock_guard<std::mutex> lock(g.sessions_mutex);
        s->id = "s" + std::to_string(g.next_session++);
        g.sessions[s->id] = s;
    }
    log_line(1, "open " + s->id + " " + s->path + " " + std::to_string(d.frame.width) + "x" +
                    std::to_string(d.frame.height) + " decode " + std::to_string(int(d.decode_ms)) + " ms, open " +
                    std::to_string(int(open_ms)) + " ms");
    if(d.pair) {
        unsigned bitmaps=0,meters=0,present=0;
        for(const auto& hole:d.pair->sources){present+=hole.present();bitmaps+=hole.bitmap_reused;meters+=hole.meter_reused;}
        log_line(1,"pair sources: present="+std::to_string(present)+", bitmap_hits="+std::to_string(bitmaps)+", saved_meter_hits="+std::to_string(meters));
    }
    return open_reply(*s, d, opened, open_ms);
}

// R2: decode the session's file again with other decode settings, keeping its
// id and its params. The engine session is replaced (a new source means a new
// negative); on any failure the old one is untouched.
Json m_redecode(const Request& q) {
    auto s = find_session(q.params);
    const DecodeOptions options = decode_options(q.params.at("decode"));
    char* current = nullptr;
    const spk_status st = spk_get_params(s->handle, &current);
    if (st != SPK_OK) engine_fail(st, "get_params");
    Json params = take_json(current);
    Decoded d = decode_frame(utf8_path(s->path), options,params,false,0,s->pair_client_presentation);
    prepare_pair(d,params);
    Json opened;
    double open_ms = 0;
    spk_session* handle = engine_open(d.frame, params.dump(), opened, open_ms);
    try { remember_params(*s, opened.at("params")); }
    catch (...) { spk_session_release(handle); throw; }
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
    s->pair_info=d.pair?pair_info(*d.pair):Json();
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
    Json candidate = s->params;
    for (const auto& field : delta.fields()) candidate.set(field.first, field.second);
    check_cineon_request(candidate);
    if(!s->pair_info.is_null()) {
        if(candidate.at("auto_exposure").as_bool() || !candidate.at("overscan_pair").as_bool() || candidate.at("overscan_format").as_string()!="135_half")
            throw HostError{"bad_request","a half-frame pair keeps two holes and meters each hole independently"};
        // Changing the strip/gap or meter changes the scene-linear decode;
        // commit the replacement only after both decode and engine open succeed.
        bool rebuild=false;
        for(const char* k:{"overscan_active","auto_exposure_method","film_stock"})
            if(candidate.at(k).dump()!=s->params.at(k).dump()) rebuild=true;
        if(rebuild) {
            auto d=decode_frame(utf8_path(s->path),DecodeOptions{},candidate,false,0,s->pair_client_presentation);
            prepare_pair(d,candidate);
            Json opened; double ms=0;
            spk_session* next=engine_open(d.frame,candidate.dump(),opened,ms);
            try { remember_params(*s,opened.at("params")); }
            catch(...) {spk_session_release(next); throw;}
            auto old=s->handle; s->handle=next; spk_session_release(old);
            s->width=d.frame.width; s->height=d.frame.height; s->metadata=d.probe.metadata; s->pair_info=pair_info(*d.pair);
            Json r=Json::object(); r.set("params",opened.at("params")); r.set("pair",s->pair_info); return r;
        }
    }
    char* reply = nullptr;
    const spk_status st = spk_set_params(s->handle, delta.dump().c_str(), &reply);
    if (st != SPK_OK) { if (reply) spk_string_free(reply); engine_fail(st, "set_params"); }
    Json out = take_json(reply);
    remember_params(*s, out.at("params"));
    Json r = Json::object();
    r.set("params", out.at("params"));
    if (out.has("invalidated")) r.set("invalidated", out.at("invalidated"));
    return r;
}

Json m_get_params(const Request& q) {
    auto s = find_session(q.params);
    char* reply = nullptr;
    const spk_status st = spk_get_params(s->handle, &reply);
    if (st != SPK_OK) engine_fail(st, "get_params");
    Json r = Json::object();
    r.set("params", take_json(reply));
    return r;
}

Json m_solve(const Request& q) {
    auto s = find_session(q.params);
    const std::string target = optional_string(q.params, "target", "both");
    if(!s->pair_info.is_null() && target!="filter_pack") throw HostError{"bad_request","pair exposure is metered per hole; solve only filter_pack on the assembled strip"};
    char* reply = nullptr;
    const spk_status st = spk_solve(s->handle, target.c_str(), &reply);
    if (st != SPK_OK) engine_fail(st, "solve");
    Json solved=take_json(reply);
    char* current=nullptr;
    const auto read=spk_get_params(s->handle,&current);
    if(read!=SPK_OK) { if(current) spk_string_free(current); engine_fail(read,"get solved params"); }
    remember_params(*s,take_json(current));
    return solved;
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
    package_pixels(result.r, s->output_space, q.params, image, payload, s->cineon);
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

// One worker owns the complete override/reprint/restore transaction. A layer
// never leaves the session (or the next queued request) with its print selected.
Json m_render_layer(const Request& q,std::vector<uint8_t>& payload) {
    auto s=find_session(q.params);
    if(s->pair_info.is_null()||!s->pair_client_presentation) throw HostError{"bad_request","render_layer needs a client-presented pair session"};
    const Json& delta=q.params.at("delta");
    if(!delta.is_object()||delta.fields().empty()) throw HostError{"bad_request","a print layer needs its delta"};
    const std::set<std::string> fields{"print_exposure","y_filter_shift","m_filter_shift","preflash_exposure"};
    Json restore=Json::object();
    for(const auto& f:delta.fields()) {
        if(!fields.count(f.first)||!f.second.is_number()||!std::isfinite(f.second.as_double())) throw HostError{"bad_request","render_layer accepts only finite enlarger print fields"};
        restore.set(f.first,s->params.at(f.first));
    }
    Request change;change.params=Json::object();change.params.set("session",str(s->id));change.params.set("delta",delta);
    Request reset=change;reset.params.set("delta",restore);
    try {
        m_set_params(change);
        Request render=q;render.params.set("reprint",Json(true));
        Json result=m_render(render,payload);
        m_set_params(reset);
        return result;
    } catch(...) {
        // Restore even if the pixel format/transform/render itself failed.
        m_set_params(reset);
        throw;
    }
}

Json m_scene_latitude(const Request& q) {
    auto s = find_session(q.params);
    const Json& request = q.params.at("request");
    const std::string text = request.is_object() ? request.dump() : std::string();
    char* reply = nullptr;
    const spk_status st = spk_scene_latitude(s->handle, text.empty() ? nullptr : text.c_str(), &reply);
    if (st != SPK_OK) engine_fail(st, "scene_latitude");
    return take_json(reply);
}

Json m_overscan_geometry(const Request& q) {
    auto s = find_session(q.params);
    char* reply = nullptr;
    const spk_status st = spk_overscan_geometry(s->handle, &reply);
    if (st != SPK_OK) engine_fail(st, "overscan_geometry");
    return take_json(reply);
}

Json m_pair_info(const Request& q) {
    return find_session(q.params)->pair_info;
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
    auto s = find_session(q.params);
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

Json m_export_image(const Request& q) {
    auto s = find_session(q.params);
    if(s->pair_client_presentation) throw HostError{"unsupported","this pair requires client print/grade composition; export through write_image"};
    if(!s->pair_info.is_null() && !s->pair_info.at("can_export").as_bool()) throw HostError{"bad_request","a pair with an empty or missing hole cannot be exported"};
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
    std::vector<uint16_t> viewed;
    const uint16_t* pixels = result.r.rgba16;
    uint32_t stride = result.r.row_stride_px ? result.r.row_stride_px : w;
    if (s->cineon) {
        g.cineon_view.apply(pixels, w, h, stride, viewed);
        pixels = viewed.data(); stride = w;
    }
    t.to_linear(pixels, w, h, stride, lin);
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
        if(is_pair_path(utf8_path(source))) {
            auto s=find_session(q.params);
            if(s->path!=source || s->pair_info.is_null() || !s->pair_info.at("can_export").as_bool())
                throw HostError{"bad_request","pair write_image requires its complete open session"};
            exif=exif_of(s->metadata);
        } else {
            Probe probe;
            std::string why;
            if (probe_file(utf8_path(source), probe, why)) exif = exif_of(probe.metadata);
            else log_line(1, "write_image: no EXIF from " + source + ": " + why);
        }
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
    if(!s->pair_info.is_null() && !s->pair_info.at("can_export").as_bool()) throw HostError{"bad_request","a pair with an empty or missing hole cannot be exported"};
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

// A raw Cineon file is different from legacy export_di's normalised density.
// The editor may supply its crop here because ordinary unframed geometry is
// a presentation edit there. Restore the live session on every exit path.
struct CineonParams {
    spk_session* session;
    Json restore = Json::object();
    bool changed = false;
    explicit CineonParams(spk_session* s) : session(s) {}
    void apply(const Json& geometry) {
        char* text = nullptr;
        auto st = spk_get_params(session, &text);
        if (st != SPK_OK) engine_fail(st, "Cineon get_params");
        const Json current = take_json(text);
        Json delta = Json::object();
        if (!geometry.is_null() && !geometry.is_object()) throw HostError{"bad_request", "geometry must be an object"};
        const std::set<std::string> allowed = {"geometry_crop_x", "geometry_crop_y", "geometry_crop_w", "geometry_crop_h",
            "geometry_rotation_deg", "geometry_quarter_turns", "geometry_flip_h", "geometry_flip_v"};
        for (const auto& field : geometry.fields()) {
            if (!allowed.count(field.first)) throw HostError{"bad_request", "not a Cineon geometry field: " + field.first};
            if (field.second.dump() == current.at(field.first).dump()) continue;
            delta.set(field.first, field.second);
            restore.set(field.first, current.at(field.first));
        }
        if (output_space_of(current) != "ProPhoto RGB") {
            delta.set("output_color_space", str("ProPhoto RGB"));
            restore.set("output_color_space", current.at("output_color_space"));
        }
        if (delta.fields().empty()) return;
        st = spk_set_params(session, delta.dump().c_str(), nullptr);
        if (st != SPK_OK) engine_fail(st, "Cineon geometry");
        changed = true;
    }
    void finish() {
        if (!changed) return;
        const auto st = spk_set_params(session, restore.dump().c_str(), nullptr);
        if (st != SPK_OK) engine_fail(st, "restore after Cineon export");
        changed = false;
    }
    ~CineonParams() {
        if (changed && spk_set_params(session, restore.dump().c_str(), nullptr) != SPK_OK)
            log_line(0, "could not restore session after failed Cineon export");
    }
};

Json m_export_cineon(const Request& q) {
    auto s = find_session(q.params);
    if(!s->pair_info.is_null() && !s->pair_info.at("can_export").as_bool()) throw HostError{"bad_request","a pair with an empty or missing hole cannot be exported"};
    if (!g.cineon_view.ready()) throw HostError{"unsupported", "Cineon DI view resources: " + g.cineon_error};
    const fs::path path = utf8_path(require_string(q.params, "path"));
    const bool overwrite = q.params.at("overwrite").as_bool(false);
    std::error_code ec;
    if (!overwrite && fs::exists(path, ec)) throw HostError{"io_error", "destination exists: " + path_utf8(path)};
    const std::string progress_id = optional_string(q.params, "progress_id");
    Running running(s->id, progress_id);
    progress_event(*s, progress_id, 0, "render Cineon");
    CineonParams temporary(s->handle);
    temporary.apply(q.params.at("geometry"));
    Result result;
    char* reply = nullptr;
    const auto st = spk_render_digital_intermediate(s->handle, &result.r, &reply);
    if (st != SPK_OK) { if (reply) spk_string_free(reply); engine_fail(st, "render Cineon"); }
    Json info = take_json(reply);
    temporary.finish();
    const uint32_t w = result.r.width, h = result.r.height;
    const uint32_t stride = result.r.row_stride_px ? result.r.row_stride_px : w;
    std::vector<uint16_t> rgb(size_t(w) * h * 3);
    for (uint32_t y = 0; y < h; ++y)
        for (uint32_t x = 0; x < w; ++x)
            for (int c = 0; c < 3; ++c) rgb[(size_t(y) * w + x) * 3 + c] = result.r.rgba16[(size_t(y) * stride + x) * 4 + c];
    std::string error;
    Json luts = Json::array();
    for (const char* name : CineonView::names) {
        std::vector<uint8_t> bytes, existing;
        if (!read_file(g.resources / "di" / name, bytes, error)) throw HostError{"io_error", error};
        const auto target = path.parent_path() / name;
        if (fs::exists(target, ec)) {
            if (!read_file(target, existing, error)) throw HostError{"io_error", error};
            if (existing != bytes) throw HostError{"io_error", "an existing DI view LUT differs from the bundled original: " + path_utf8(target)};
        } else if (!write_file_atomic(target, bytes, false, error)) throw HostError{"io_error", error};
        luts.push(str(path_utf8(target)));
    }
    std::vector<uint8_t> bytes;
    Exif exif = exif_of(s->metadata);
    exif.uncalibrated = true;
    TiffPreview preview;
    preview.width = w; preview.height = h;
    {
        // Mac always supplies a second, viewed 8-bit page for log files.
        // This is the same LUT as render, with no finished Post-Dev grade.
        std::vector<uint16_t> viewed;
        g.cineon_view.apply(result.r.rgba16, w, h, stride, viewed);
        const auto& t = transform("ProPhoto RGB", "ProPhoto RGB");
        std::vector<float> lin;
        t.to_linear(viewed.data(), w, h, w, lin);
        viewed.clear(); viewed.shrink_to_fit();
        shrink_to(lin, preview.width, preview.height, 2048);
        std::vector<uint8_t> rgba;
        t.encode_rgba8(lin, rgba);
        preview.rgb.resize(size_t(preview.width) * preview.height * 3);
        for (size_t i = 0; i < preview.rgb.size() / 3; ++i)
            for (int c = 0; c < 3; ++c) preview.rgb[i * 3 + c] = rgba[i * 4 + c];
        if (!icc_for("ProPhoto RGB", g.resources, preview.icc, error)) throw HostError{"io_error", error};
    }
    // Codes, not ordinary encoded RGB: only the viewed preview has an ICC.
    if (!encode_tiff(rgb.data(), w, h, 16, {}, bytes, error, &exif, &preview)) throw HostError{"io_error", error};
    if (!write_file_atomic(path, bytes, overwrite, error)) throw HostError{"io_error", error};
    Json r = written(path, w, h, bytes.size(), "");
    r.set("di", std::move(info));
    r.set("view_luts", std::move(luts));
    progress_event(*s, progress_id, 1, "done");
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
    else if (m == "open") result = m_open(q);
    else if (m == "close") result = m_close(q);
    else if (m == "redecode") result = m_redecode(q);
    else if (m == "set_params") result = m_set_params(q);
    else if (m == "get_params") result = m_get_params(q);
    else if (m == "solve") result = m_solve(q);
    else if (m == "render") result = m_render(q, payload);
    else if (m == "scene_latitude") result = m_scene_latitude(q);
    else if (m == "overscan_geometry") result = m_overscan_geometry(q);
    else if (m == "render_layer") result = m_render_layer(q,payload);
    else if (m == "pair_info") result = m_pair_info(q);
    else if (m == "preview_stock_lut") result = m_preview_stock_lut(q, payload);
    else if (m == "progress") result = m_progress(q);
    else if (m == "export_image") result = m_export_image(q);
    else if (m == "write_image") result = m_write_image(q);
    else if (m == "export_cube") result = m_export_cube(q);
    else if (m == "export_di") result = m_export_di(q);
    else if (m == "export_cineon") result = m_export_cineon(q);
    else throw HostError{"unsupported", "unknown method '" + m + "'"};
    respond_ok(q.id, std::move(result), payload.data(), payload.size());
}

// --- threads ---------------------------------------------------------------------

std::mutex g_queue_mutex;
std::condition_variable g_queue_cv;
std::deque<Request> g_queue;
bool g_queue_closed = false;

void worker() {
    for (;;) {
        Request q;
        {
            std::unique_lock<std::mutex> lock(g_queue_mutex);
            g_queue_cv.wait(lock, [] { return g_queue_closed || !g_queue.empty(); });
            if (g_queue.empty()) return;
            q = std::move(g_queue.front());
            g_queue.pop_front();
        }
        const auto t0 = Clock::now();
        try {
            dispatch(q);
        } catch (const HostError& e) {
            respond_error(q.id, e.code, e.message);
        } catch (const std::bad_alloc&) {
            respond_error(q.id, "internal", "out of memory");
        } catch (const std::exception& e) {
            respond_error(q.id, "internal", e.what());
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
        running = g.running_session == session && (progress.empty() || g.running_progress == progress);
        if (!running && !progress.empty()) g.cancelled.insert({session, progress});
    }
    if (running) {
        std::lock_guard<std::mutex> lock(g.sessions_mutex);
        auto it = g.sessions.find(session);
        if (it != g.sessions.end() && it->second->handle) spk_cancel(it->second->handle, nullptr);
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
    if (!g.cineon_view.load(g.resources, g.cineon_error))
        log_line(0, "Cineon DI view unavailable: " + g.cineon_error);
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
