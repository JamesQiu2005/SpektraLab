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
#include <set>
#include <string>
#include <thread>
#include <vector>

#include "image_io.hpp"
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
    if (!m.datetime_original.empty()) j.set("datetime_original", str(iso_datetime(m.datetime_original)));
    j.set("orientation", number(m.orientation));
    return j;
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
    r.set("backend", std::move(backend));
    r.set("capabilities", std::move(caps));
    Json methods = Json::array();
    for (const char* m : {"hello", "ping", "shutdown", "params_schema", "print_lut_catalog", "memory_report",
                          "probe", "thumbnail", "open", "close", "set_params", "get_params", "solve", "render",
                          "scene_latitude", "overscan_geometry", "preview_stock_lut", "cancel", "progress",
                          "export_image", "export_cube", "export_di", "write_image"})
        methods.push(str(m));
    r.set("methods", std::move(methods));
    return r;
}

Json m_params_schema(const Request&) { need_engine(); return parse_json(spk_params_schema(g.engine)); }
Json m_print_lut_catalog(const Request&) { need_engine(); return parse_json(spk_print_lut_catalog(g.engine)); }
Json m_memory_report(const Request&) { need_engine(); return parse_json(spk_memory_report(g.engine)); }

Json m_probe(const Request& q) {
    Probe p;
    std::string error;
    const fs::path path = utf8_path(require_string(q.params, "path"));
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

Json m_open(const Request& q) {
    need_engine();
    const fs::path path = utf8_path(require_string(q.params, "path"));
    DecodeOptions options;
    const Json& decode = q.params.at("decode");
    if (decode.is_object()) {
        options.raw_mode = optional_string(decode, "raw_mode", "compatible16");
        if (options.raw_mode != "compatible16" && options.raw_mode != "headroom")
            throw HostError{"bad_request", "decode.raw_mode must be compatible16 or headroom"};
        for (const auto& kv : decode.fields())
            if (kv.first != "raw_mode")
                throw HostError{"unsupported", "decode." + kv.first + " is not supported by this host"};
    }
    std::error_code ec;
    if (!fs::exists(path, ec)) throw HostError{"not_found", "not found: " + path_utf8(path)};
    const auto t0 = Clock::now();
    FloatImage frame;
    Probe probe;
    std::string error;
    if (!decode_linear_prophoto(path, options, frame, probe, error)) throw HostError{"decode_failed", error};
    const double decode_ms = ms_since(t0);

    const auto t1 = Clock::now();
    spk_image image{frame.rgb.data(), frame.width, frame.height, 3};
    std::string delta;
    const Json& params = q.params.at("params");
    if (params.is_object()) delta = params.dump();
    char* reply = nullptr;
    spk_session* handle = spk_open(g.engine, &image, delta.empty() ? nullptr : delta.c_str(), &reply);
    if (!handle) {
        if (reply) spk_string_free(reply);
        throw HostError{"engine_error", std::string("open: ") + spk_last_error(g.engine)};
    }
    Json opened = take_json(reply);
    const double open_ms = ms_since(t1);

    auto s = std::make_shared<Session>();
    s->handle = handle;
    s->path = path_utf8(path);
    s->width = frame.width;
    s->height = frame.height;
    s->metadata = probe.metadata;
    s->metadata.orientation = 1;   // the frame handed to the engine is upright
    s->output_space = output_space_of(opened.at("params"));
    {
        std::lock_guard<std::mutex> lock(g.sessions_mutex);
        s->id = "s" + std::to_string(g.next_session++);
        g.sessions[s->id] = s;
    }
    log_line(1, "open " + s->id + " " + s->path + " " + std::to_string(frame.width) + "x" +
                    std::to_string(frame.height) + " decode " + std::to_string(int(decode_ms)) + " ms, open " +
                    std::to_string(int(open_ms)) + " ms");
    Json r = Json::object();
    r.set("session", str(s->id));
    r.set("width", number(frame.width));
    r.set("height", number(frame.height));
    r.set("kind", str(kind_name(probe.kind)));
    Json meta = metadata_json(probe.metadata);
    meta.set("orientation", number(probe.metadata.orientation));
    r.set("metadata", std::move(meta));
    r.set("params", opened.at("params"));
    r.set("detected_input", opened.at("detected_input"));
    r.set("output_color_space", str(s->output_space));
    Json timings = Json::object();
    timings.set("decode", number(decode_ms));
    timings.set("open", number(open_ms));
    r.set("timings_ms", std::move(timings));
    return r;
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
                 const std::string& format, int quality, const std::vector<uint8_t>& icc, std::vector<uint8_t>& out) {
    std::string error;
    if (format == "tiff16") {
        std::vector<uint16_t> rgba;
        t.encode_rgba16(lin, rgba);
        std::vector<uint16_t> rgb(size_t(w) * h * 3);
        for (size_t p = 0; p < size_t(w) * h; ++p) for (int c = 0; c < 3; ++c) rgb[p * 3 + c] = rgba[p * 4 + c];
        if (!encode_tiff(rgb.data(), w, h, 16, icc, out, error)) throw HostError{"io_error", error};
        return;
    }
    std::vector<uint8_t> rgba;
    t.encode_rgba8(lin, rgba);
    std::vector<uint8_t> rgb(size_t(w) * h * 3);
    for (size_t p = 0; p < size_t(w) * h; ++p) for (int c = 0; c < 3; ++c) rgb[p * 3 + c] = rgba[p * 4 + c];
    bool ok = false;
    if (format == "tiff8") ok = encode_tiff(rgb.data(), w, h, 8, icc, out, error);
    else if (format == "png") ok = encode_png8(rgb.data(), w, h, icc, out, error);
    else if (format == "jpeg") ok = encode_jpeg(rgb.data(), w, h, quality, icc, out, error);
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
    encode_file(t, lin, w, h, format, quality, icc, bytes);
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
    const size_t pixels = size_t(w) * h;
    auto sample = [&](size_t i) { return uint16_t(q.payload[2 * i] | (q.payload[2 * i + 1] << 8)); };
    bool ok;
    if (format == "tiff16") {
        std::vector<uint16_t> rgb(pixels * 3);
        for (size_t p = 0; p < pixels; ++p) for (int c = 0; c < 3; ++c) rgb[p * 3 + c] = sample(p * 4 + c);
        ok = encode_tiff(rgb.data(), uint32_t(w), uint32_t(h), 16, icc, bytes, error);
    } else {
        std::vector<uint8_t> rgb(pixels * 3);
        for (size_t p = 0; p < pixels; ++p)
            for (int c = 0; c < 3; ++c) rgb[p * 3 + c] = uint8_t((uint32_t(sample(p * 4 + c)) * 255 + 32767) / 65535);
        if (format == "tiff8") ok = encode_tiff(rgb.data(), uint32_t(w), uint32_t(h), 8, icc, bytes, error);
        else if (format == "png") ok = encode_png8(rgb.data(), uint32_t(w), uint32_t(h), icc, bytes, error);
        else ok = encode_jpeg(rgb.data(), uint32_t(w), uint32_t(h), quality, icc, bytes, error);
    }
    if (!ok) throw HostError{"io_error", error};
    if (!write_file_atomic(path, bytes, overwrite, error)) throw HostError{"io_error", error};
    Json r = written(path, uint32_t(w), uint32_t(h), bytes.size(), space);
    r.set("exif_copied", Json(false));
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
    else if (m == "open") result = m_open(q);
    else if (m == "close") result = m_close(q);
    else if (m == "set_params") result = m_set_params(q);
    else if (m == "get_params") result = m_get_params(q);
    else if (m == "solve") result = m_solve(q);
    else if (m == "render") result = m_render(q, payload);
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
    std::string resources;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "--resources" && i + 1 < argc) resources = argv[++i];
        else if (a == "--device" && i + 1 < argc) {
            const std::string v = argv[++i];
#ifdef _WIN32
            _putenv_s("SPEKTRAFILM_VULKAN_DEVICE", v.c_str());
#else
            setenv("SPEKTRAFILM_VULKAN_DEVICE", v.c_str(), 1);
#endif
        } else if (a == "--log-level" && i + 1 < argc) {
            const std::string v = argv[++i];
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
    if (resources.empty()) {
        // Beside the executable, as build/host-<os>-x64/ stages it.
        std::error_code ec;
        const fs::path self = fs::canonical(fs::path(argv[0]), ec);
        if (!ec) resources = path_utf8(self.parent_path() / "engine");
    }
    g.resources = utf8_path(resources);
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
