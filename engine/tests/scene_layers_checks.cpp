// scene_layers_checks.cpp -- RFC-052 §10's engine gates for the 场景 layers
// (API-SPEC §23), through the C ABI on this Mac's own device, as the app calls
// it: the planes are real `MTLBuffer`s handed to `spk_set_scene_layers`.
//
//   scene_layers_checks <resources> gates          gates 1, 2, 3, 4, 5, the stamp, the negative, §11's paths
//   scene_layers_checks <resources> hashes         gate 2's no-layer renders, sha256 (build with -DSPK_BASELINE
//                                                  against another engine to hold the two to the bit)
//   scene_layers_checks <resources> cost W H N     gate 6: one develop of a W x H frame with N layers; one case
//                                                  per process, so its peak phys_footprint is its own
//
// Every render is the full tier of a synthetic frame (no file decode), Portra
// 400 -> Portra Endura, product defaults, grain and glare off unless a gate
// says otherwise, auto-exposure off except for the meter's gate. Output is the
// engine's rgba16; "counts" are its 16-bit codes (1 count = 1.5e-5, half the
// parity suite's 3e-5 bar).
#include <Foundation/Foundation.hpp>
#include <Metal/Metal.hpp>
#include <CommonCrypto/CommonDigest.h>
#include <mach/mach.h>
#include <spektralab/spk_engine.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

#include "json.hpp"

namespace {

int failures = 0;
void check(bool ok, const std::string& what, const std::string& detail = "") {
    std::printf("%s  %s%s\n", ok ? "ok  " : "FAIL", what.c_str(), detail.empty() ? "" : ("  -- " + detail).c_str());
    std::fflush(stdout);
    if (!ok) ++failures;
}

std::string fmt(const char* f, ...) __attribute__((format(printf, 1, 2)));
std::string fmt(const char* f, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, f);
    std::vsnprintf(buf, sizeof buf, f, ap);
    va_end(ap);
    return buf;
}

MTL::Device* g_device = nullptr;
spk_engine* g_engine = nullptr;

constexpr double kMid = 0.184;
constexpr double kLn2 = 0.69314718055994530942;

// A tight RGB copy of a result (rgba16 rows are padded to the texture's alignment).
struct Frame {
    uint32_t w = 0, h = 0;
    std::vector<uint16_t> px;   // RGB
    double at(uint32_t x, uint32_t y, int c) const { return double(px[3 * (size_t(y) * w + x) + size_t(c)]); }
};

std::string sha256(const Frame& f) {
    unsigned char d[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(f.px.data(), CC_LONG(f.px.size() * sizeof(uint16_t)), d);
    std::string s;
    for (int i = 0; i < 8; ++i) s += fmt("%02x", d[i]);
    return s;
}

spk::Json parse(char* text) {
    spk::Json j;
    std::string err;
    if (text) { spk::Json::parse(text, j, err); spk_string_free(text); }
    return j;
}

std::string base_delta(const std::string& extra = "") {
    std::string d = R"("film_stock": "kodak_portra_400", "print_stock": "kodak_portra_endura", )"
                    R"("product_defaults": true, "grain_active": false, "glare_active": false, "auto_exposure": false)";
    if (!extra.empty()) d += ", " + extra;
    return "{" + d + "}";
}

spk_session* open(const std::vector<float>& rgb, uint32_t w, uint32_t h, const std::string& delta) {
    spk_image img{rgb.data(), w, h, 3};
    char* reply = nullptr;
    spk_session* s = spk_open(g_engine, &img, delta.c_str(), &reply);
    if (reply) spk_string_free(reply);
    if (!s) std::printf("open failed: %s\n", spk_last_error(g_engine));
    return s;
}

bool set_params(spk_session* s, const std::string& delta) {
    char* reply = nullptr;
    const spk_status st = spk_set_params(s, delta.c_str(), &reply);
    if (reply) spk_string_free(reply);
    if (st != SPK_OK) std::printf("set_params failed: %s\n", spk_last_error(g_engine));
    return st == SPK_OK;
}

spk_status render(spk_session* s, Frame& out, const char* tier = "full", bool reprint = false,
                  spk_result* keep = nullptr) {
    spk_result r{};
    const spk_status st = reprint ? spk_reprint(s, tier, &r) : spk_render(s, tier, &r);
    if (st != SPK_OK) return st;
    out.w = r.width; out.h = r.height;
    out.px.resize(size_t(r.width) * r.height * 3);
    for (uint32_t y = 0; y < r.height; ++y)
        for (uint32_t x = 0; x < r.width; ++x)
            for (int c = 0; c < 3; ++c)
                out.px[3 * (size_t(y) * r.width + x) + size_t(c)] = r.rgba16[4 * (size_t(y) * r.row_stride_px + x) + size_t(c)];
    if (keep) *keep = r;
    spk_result_free(&r);
    return st;
}

struct Diff { double max = 0, mean = 0, over1 = 0; bool shape = true; };
Diff diff(const Frame& a, const Frame& b) {
    Diff d;
    if (a.w != b.w || a.h != b.h) { d.shape = false; d.max = 1e9; return d; }
    double sum = 0;
    size_t over = 0;
    for (size_t i = 0; i < a.px.size(); ++i) {
        const double v = std::fabs(double(a.px[i]) - double(b.px[i]));
        d.max = std::max(d.max, v);
        sum += v;
        over += v > 1.0;
    }
    d.mean = sum / double(a.px.size());
    d.over1 = double(over) / double(a.px.size());
    return d;
}
std::string describe(const Diff& d) {
    if (!d.shape) return "shapes differ";
    return fmt("max %.0f counts (%.2e), mean %.4f counts (%.2e), %.5f %% over 1 count", d.max, d.max / 65535.0,
               d.mean, d.mean / 65535.0, 100.0 * d.over1);
}

// --- planes --------------------------------------------------------------

// A plane whose texel (i, j) holds f(S) at its centre ((i + 0.5)/W, (j + 0.5)/H), f in [0, 1].
MTL::Buffer* plane(uint32_t w, uint32_t h, const std::function<double(double, double)>& f) {
    MTL::Buffer* b = g_device->newBuffer(size_t(w) * h * 2, MTL::ResourceStorageModeShared);
    auto* p = static_cast<uint16_t*>(b->contents());
    for (uint32_t j = 0; j < h; ++j)
        for (uint32_t i = 0; i < w; ++i) {
            const double v = std::clamp(f((i + 0.5) / w, (j + 0.5) / h), 0.0, 1.0);
            p[size_t(j) * w + i] = uint16_t(std::lround(v * 65535.0));
        }
    return b;
}
MTL::Buffer* full_plane(uint32_t w = 4, uint32_t h = 4) { return plane(w, h, [](double, double) { return 1.0; }); }

spk_scene_layer layer(MTL::Buffer* b, uint32_t w, uint32_t h, double e_stops, double coverage = 1.0,
                      const double colour[3] = nullptr) {
    spk_scene_layer l{};
    l.plane = b; l.width = w; l.height = h; l.coverage = float(coverage);
    for (int c = 0; c < 3; ++c) l.log_gain[c] = float(e_stops * kLn2 + (colour ? colour[c] : 0.0));
    return l;
}

spk_status hand(spk_session* s, const std::vector<spk_scene_layer>& ls, const char* stamp,
                const float* f2s = nullptr, spk::Json* reply = nullptr) {
    char* out = nullptr;
    const spk_status st = spk_set_scene_layers(s, ls.empty() ? nullptr : ls.data(), uint32_t(ls.size()), f2s, stamp, &out);
    spk::Json j = parse(out);
    if (reply) *reply = j;
    if (st != SPK_OK) std::printf("spk_set_scene_layers: %s\n", spk_last_error(g_engine));
    return st;
}

// --- frames --------------------------------------------------------------

// Gate 1's scene: stops -7 ... +5 about mid-grey along x, a hue turning along y.
std::vector<float> ramp_frame(uint32_t w, uint32_t h) {
    std::vector<float> f(size_t(w) * h * 3);
    for (uint32_t y = 0; y < h; ++y)
        for (uint32_t x = 0; x < w; ++x) {
            const double stops = -7.0 + 12.0 * (x + 0.5) / w;
            const double a = 2.0 * M_PI * (y + 0.5) / h;
            const double v = kMid * std::pow(2.0, stops);
            for (int c = 0; c < 3; ++c)
                f[3 * (size_t(y) * w + x) + size_t(c)] = float(v * (1.0 + 0.55 * std::cos(a + 2.0943951 * c)));
        }
    return f;
}

// A five-row Decode curve (API-SPEC §17): the rgb row lifted in the middle, a red row bent, the rest identity.
std::string decode_curve() {
    const int n = 17;
    std::string s;
    for (int row = 0; row < 5; ++row)
        for (int i = 0; i < n; ++i) {
            const double x = double(i) / (n - 1);
            double y = x;
            if (row == 0) y = x + 0.06 * std::sin(M_PI * x);
            if (row == 2) y = x - 0.03 * std::sin(M_PI * x);
            if (!s.empty()) s += ",";
            s += fmt("%.6f", std::clamp(y, 0.0, 1.0));
        }
    return s;
}

std::string latitude_and_curve() {
    return R"("scene_latitude_active": true, "scene_latitude_highlight_knee": 1.0, "scene_latitude_highlight_room": 1.5, )"
           R"("scene_latitude_shadow_knee": -2.0, "scene_latitude_shadow_room": 1.0, "scene_curve": ")" + decode_curve() + "\"";
}

// Gate 2's configurations, shared with `hashes`.
struct NeutralCase { const char* name; const char* extra; };
const NeutralCase kNeutralConfigs[] = {
    {"defaults", ""},
    {"latitude + curve", "LAT"},
    {"cut: crop, straighten, turn, flip", R"("geometry_crop_x": 0.1, "geometry_crop_y": 0.05, "geometry_crop_w": 0.8, "geometry_crop_h": 0.85, "geometry_rotation_deg": 3.5, "geometry_quarter_turns": 1, "geometry_flip_h": true)"},
    {"striped, 100 rows", R"("striped": true, "strip_rows": 100)"},
};
std::string neutral_extra(const NeutralCase& n) { return std::string(n.extra) == "LAT" ? latitude_and_curve() : n.extra; }

#ifndef SPK_BASELINE

// --- gate 1: the full-mask identity ---------------------------------------

void gate1() {
    std::printf("\n== gate 1: a full-mask layer of e stops is Film Exposure + e ==\n");
    const uint32_t W = 1200, H = 800;
    const std::vector<float> frame = ramp_frame(W, H);
    const double c = 0.3;
    MTL::Buffer* p = full_plane();
    for (int with = 0; with < 2; ++with) {
        const std::string extra = with ? latitude_and_curve() : std::string();
        for (double e : {-2.0, -0.5, 0.5, 2.0}) {
            const std::string sep = extra.empty() ? "" : ", ";
            spk_session* a = open(frame, W, H, base_delta(fmt("\"exposure_compensation_ev\": %.17g", c + e) + sep + extra));
            spk_session* b = open(frame, W, H, base_delta(fmt("\"exposure_compensation_ev\": %.17g, \"scene_layers\": \"one\"", c) + sep + extra));
            Frame fa, fb;
            const bool ok = a && b && hand(b, {layer(p, 4, 4, e)}, "one") == SPK_OK &&
                            render(a, fa) == SPK_OK && render(b, fb) == SPK_OK;
            const Diff d = diff(fa, fb);
            check(ok && d.max <= 2.0, fmt("identity, e = %+.1f, c = %.1f%s", e, c, with ? ", Scene Latitude + Decode curve on" : ""),
                  describe(d));
            spk_session_release(a);
            spk_session_release(b);
        }
    }
    // The rejected place (§6.3, after the Decode curve) is what this gate would
    // catch; shown by building the node there once (the commit records it).

    // The colour path: a colour gain on a full mask against the same gain applied by hand to the input.
    std::printf("\n== gate 1, colour: C^-1 diag(exp g) C, the round trip ==\n");
    spk_session* b = open(frame, W, H, base_delta("\"scene_layers\": \"tint\""));
    const double tint[3] = {0.12, -0.04, -0.20};
    spk::Json reply;
    hand(b, {layer(p, 4, 4, 0.0, 1.0, tint)}, "tint", nullptr, &reply);
    double C[9], Ci[9];
    for (int k = 0; k < 9; ++k) { C[k] = reply.at("rgb_to_cone").items()[size_t(k)].as_double(); Ci[k] = reply.at("cone_to_rgb").items()[size_t(k)].as_double(); }
    check(reply.at("colour").as_bool(), "the reply flags a colour set", reply.at("working_space").as_string());
    // C held against an independent spelling: colour-science's `RGB_COLOURSPACE_PROPHOTO_RGB` matrix (the
    // published four-decimal one, `use_derived_matrix_RGB_to_XYZ` False -- 1.9e-4 from the one its primaries
    // derive, measured here) and the CAT16 matrix as published.
    const double rgb2xyz[9] = {0.7977, 0.1352, 0.0313, 0.2880, 0.7119, 0.0001, 0.0, 0.0, 0.8249};
    const double m16[9] = {0.401288, 0.650173, -0.051461, -0.250268, 1.204414, 0.045854, -0.002079, 0.048952, 0.953127};
    double want[9] = {}, worst = 0, ident = 0;
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j) {
            for (int k = 0; k < 3; ++k) want[3 * i + j] += m16[3 * i + k] * rgb2xyz[3 * k + j];
            worst = std::max(worst, std::fabs(want[3 * i + j] - C[3 * i + j]));
            double cc = 0;
            for (int k = 0; k < 3; ++k) cc += Ci[3 * i + k] * C[3 * k + j];
            ident = std::max(ident, std::fabs(cc - (i == j ? 1.0 : 0.0)));
        }
    check(worst < 1e-6, "rgb_to_cone is M_CAT16 . M_ProPhoto->XYZ", fmt("max |d| %.2e against the literal matrices", worst));
    check(ident < 1e-12, "cone_to_rgb is its inverse", fmt("max |C^-1 C - I| %.2e", ident));
    // M = C^-1 diag(exp g) C, applied by hand in double to the input.
    double M[9] = {};
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j)
            for (int k = 0; k < 3; ++k) M[3 * i + j] += Ci[3 * i + k] * std::exp(double(float(tint[k]))) * C[3 * k + j];
    std::vector<float> by_hand(frame.size());
    for (size_t i = 0; i < frame.size(); i += 3)
        for (int r = 0; r < 3; ++r)
            by_hand[i + size_t(r)] = float(M[3 * r] * frame[i] + M[3 * r + 1] * frame[i + 1] + M[3 * r + 2] * frame[i + 2]);
    spk_session* a = open(by_hand, W, H, base_delta());
    Frame fa, fb;
    const bool ok = render(a, fa) == SPK_OK && render(b, fb) == SPK_OK;
    const Diff d = diff(fa, fb);
    check(ok && d.max <= 2.0, "colour gain (0.12, -0.04, -0.20) on a full mask = the same gain on the input", describe(d));
    // And that the round trip is not an identity in disguise: the picture moved.
    spk_session* n = open(frame, W, H, base_delta());
    Frame fn;
    render(n, fn);
    check(diff(fn, fb).max > 500, "... and the gain moved the picture", describe(diff(fn, fb)));
    spk_session_release(a); spk_session_release(b); spk_session_release(n);
    p->release();
}

// --- gate 2: neutral ----------------------------------------------------------

void gate2() {
    std::printf("\n== gate 2: no layers, coverage 0, zero gains -> the engine without the feature, to the bit ==\n");
    const uint32_t W = 1200, H = 800;
    const std::vector<float> frame = ramp_frame(W, H);
    MTL::Buffer* full = full_plane();
    MTL::Buffer* none = plane(64, 48, [](double, double) { return 0.0; });
    const double tint[3] = {0.1, -0.1, 0.0};
    for (const NeutralCase& cfg : kNeutralConfigs) {
        const std::string extra = neutral_extra(cfg);
        const std::string sep = extra.empty() ? "" : ", ";
        Frame ref;
        spk_session* r = open(frame, W, H, base_delta(extra));
        render(r, ref);
        spk_session_release(r);
        struct V { const char* what; const char* stamp; std::vector<spk_scene_layer> ls; };
        const std::vector<V> variants = {
            {"wire \"\", no call", "", {}},
            {"wire \"\", a set held (ignored)", "", {layer(full, 4, 4, 2.0)}},
            {"a named empty set", "n", {}},
            {"one layer at coverage 0", "z", {layer(full, 4, 4, 2.0, 0.0)}},
            {"one full layer, zero gains", "g", {layer(full, 4, 4, 0.0)}},
            {"a colour layer whose mask is 0 everywhere", "c", {layer(none, 64, 48, 0.0, 1.0, tint)}},
        };
        for (const V& v : variants) {
            const std::string wire = std::string(v.stamp).empty() ? "" : fmt("\"scene_layers\": \"%s\"", v.stamp);
            const std::string d = base_delta(extra + (wire.empty() ? "" : sep + wire));
            spk_session* s = open(frame, W, H, wire.empty() && extra.empty() ? base_delta() : d);
            const bool call = std::string(v.what) != "wire \"\", no call";
            if (call) hand(s, v.ls, v.stamp);
            Frame f;
            const spk_status st = render(s, f);
            check(st == SPK_OK && sha256(f) == sha256(ref), fmt("%s: %s", cfg.name, v.what),
                  fmt("sha %s against %s", sha256(f).c_str(), sha256(ref).c_str()));
            spk_session_release(s);
        }
    }
    // Band-able in form: under RFC-020's strips the node sees a band and its first row
    // (`band_row0_`), and a soft colour layer through a cut renders as the whole frame does.
    {
        MTL::Buffer* soft = plane(512, 341, [](double s, double t) { return std::clamp(1.5 - 3.0 * std::hypot(s - 0.4, t - 0.6), 0.0, 1.0); });
        const std::string cut = R"("geometry_crop_x": 0.1, "geometry_crop_y": 0.05, "geometry_crop_w": 0.8, "geometry_crop_h": 0.85, "geometry_rotation_deg": 3.5, "geometry_quarter_turns": 1, "scene_layers": "soft")";
        spk_session* whole = open(frame, W, H, base_delta(cut));
        spk_session* banded = open(frame, W, H, base_delta(cut + R"(, "striped": true, "strip_rows": 97)"));
        const std::vector<spk_scene_layer> ls = {layer(soft, 512, 341, 1.5), layer(full, 4, 4, -0.5, 0.5, tint)};
        hand(whole, ls, "soft");
        hand(banded, ls, "soft");
        Frame fw, fb;
        const bool ok = render(whole, fw) == SPK_OK && render(banded, fb) == SPK_OK;
        check(ok && sha256(fw) == sha256(fb), "two layers (one colour) through a cut: striped at 97 rows = the whole render",
              fmt("sha %s / %s", sha256(fw).c_str(), sha256(fb).c_str()));
        spk_session_release(whole); spk_session_release(banded);
        soft->release();
    }
    full->release(); none->release();
}

// --- gate 3: the meter --------------------------------------------------------

double solved_ev(spk_session* s) {
    char* out = nullptr;
    spk_solve(s, "exposure", &out);
    spk::Json j = parse(out);
    return j.at("solved_params").at("exposure_compensation_ev").as_double(std::nan(""));
}
double rendered_ev(spk_session* s) {
    spk_result r{};
    if (spk_render(s, "full", &r) != SPK_OK) return std::nan("");
    const std::string id = r.progress_id;
    spk_result_free(&r);
    char* out = nullptr;
    spk_progress(s, id.c_str(), &out);
    return parse(out).at("auto_exposure_ev").as_double(std::nan(""));
}

void gate3() {
    std::printf("\n== gate 3: the meter does not see a layer ==\n");
    const uint32_t W = 1200, H = 800;
    const std::vector<float> frame = ramp_frame(W, H);
    MTL::Buffer* half = plane(512, 341, [](double s, double) { return s < 0.5 ? 1.0 : 0.0; });
    for (const char* method : {"balanced", "center_weighted", "protect_highlights"}) {
        const std::string meter = fmt("\"auto_exposure\": true, \"auto_exposure_method\": \"%s\"", method);
        spk_session* a = open(frame, W, H, "{" + std::string(R"("film_stock": "kodak_portra_400", "print_stock": "kodak_portra_endura", "product_defaults": true, "grain_active": false, "glare_active": false, )") + meter + "}");
        spk_session* b = open(frame, W, H, "{" + std::string(R"("film_stock": "kodak_portra_400", "print_stock": "kodak_portra_endura", "product_defaults": true, "grain_active": false, "glare_active": false, "scene_layers": "half", )") + meter + "}");
        hand(b, {layer(half, 512, 341, 2.0)}, "half");
        const double sa = solved_ev(a), sb = solved_ev(b), ra = rendered_ev(a), rb = rendered_ev(b);
        check(sa == sb && ra == rb && sa == ra, fmt("%s: solved EV without / with a +2 layer over half the frame", method),
              fmt("solve %.9f / %.9f, applied by the render %.9f / %.9f", sa, sb, ra, rb));
        spk_session_release(a); spk_session_release(b);
    }
    half->release();
}

// --- the stamp, and the negative ------------------------------------------------

void stamp_and_negative() {
    std::printf("\n== the stamp refuses a render on another set ==\n");
    const uint32_t W = 600, H = 400;
    const std::vector<float> frame = ramp_frame(W, H);
    MTL::Buffer* left = plane(256, 171, [](double s, double) { return s < 0.5 ? 1.0 : 0.0; });
    MTL::Buffer* right = plane(256, 171, [](double s, double) { return s >= 0.5 ? 1.0 : 0.0; });
    spk_session* s = open(frame, W, H, base_delta("\"scene_layers\": \"s1\""));
    Frame f;
    spk_status st = render(s, f);
    std::string msg = spk_last_error(g_engine);
    check(st == SPK_ERR_USER && msg.find("'s1'") != std::string::npos && msg.find("no set") != std::string::npos,
          "a stamp with no set held is refused", msg);
    hand(s, {layer(left, 256, 171, 1.0)}, "s1");
    check(render(s, f) == SPK_OK, "... and renders once the set is handed");
    set_params(s, "{\"scene_layers\": \"s2\"}");
    st = render(s, f);
    msg = spk_last_error(g_engine);
    check(st == SPK_ERR_USER && msg.find("'s2'") != std::string::npos && msg.find("'s1'") != std::string::npos,
          "the wire names s2 while s1 is held: refused, both named", msg);
    st = render(s, f, "full", true);
    check(st == SPK_ERR_USER, "... a reprint too", spk_last_error(g_engine));
    st = render(s, f, "live", false);
    check(st == SPK_ERR_USER, "... and the live tier", spk_last_error(g_engine));
    hand(s, {layer(left, 256, 171, 1.0)}, "s2");
    check(render(s, f) == SPK_OK, "s2 handed: renders");
    spk_session_release(s);

    std::printf("\n== spk_set_scene_layers drops the negative: a render after a changed plane is of the new plane ==\n");
    s = open(frame, W, H, base_delta("\"scene_layers\": \"a\", \"diffusion_filter_active\": true"));
    hand(s, {layer(left, 256, 171, 1.0)}, "a");
    Frame r1, r2, fresh;
    spk_result res{};
    render(s, r1);
    char* mem = nullptr;
    mem = const_cast<char*>(spk_memory_report(g_engine));
    spk::Json before;
    std::string err;
    spk::Json::parse(mem, before, err);
    hand(s, {layer(right, 256, 171, 1.0)}, "a");   // the same stamp, another plane
    spk::Json after;
    spk::Json::parse(spk_memory_report(g_engine), after, err);
    render(s, r2, "full", true, &res);
    check(res.negative_was_cached == 0, "the reprint after the call developed again", fmt("negative_was_cached %d", res.negative_was_cached));
    spk_session* t = open(frame, W, H, base_delta("\"scene_layers\": \"a\", \"diffusion_filter_active\": true"));
    hand(t, {layer(right, 256, 171, 1.0)}, "a");
    render(t, fresh);
    check(diff(r1, r2).max > 100 && sha256(r2) == sha256(fresh), "... of the new plane",
          fmt("old vs new %s; new vs a fresh session's %s", describe(diff(r1, r2)).c_str(), describe(diff(r2, fresh)).c_str()));
    const auto row = [](const spk::Json& j) { return j.at("persistent").at("sessions").items().empty() ? spk::Json() : j.at("persistent").at("sessions").items()[0]; };
    const double lens_b = row(before).at("lensed_source_bytes").as_double(-1), lens_a = row(after).at("lensed_source_bytes").as_double(-1);
    const double src_b = row(before).at("source_bytes").as_double(-1), src_a = row(after).at("source_bytes").as_double(-1);
    check(lens_b > 0 && lens_a == lens_b && src_a == src_b, "the source and the lens's kept copy are kept",
          fmt("lensed %.0f -> %.0f bytes, source %.0f -> %.0f", lens_b, lens_a, src_b, src_a));
    spk_session_release(s); spk_session_release(t);

    // Refusals of the call itself.
    s = open(frame, W, H, base_delta());
    spk_scene_layer bad = layer(left, 256, 171, 1.0);
    bad.coverage = 1.5;
    check(spk_set_scene_layers(s, &bad, 1, nullptr, "x", nullptr) == SPK_ERR_INVALID_ARG, "coverage 1.5 is refused", spk_last_error(g_engine));
    bad = layer(left, 256, 172, 1.0);
    check(spk_set_scene_layers(s, &bad, 1, nullptr, "x", nullptr) == SPK_ERR_INVALID_ARG, "a plane shorter than width x height is refused", spk_last_error(g_engine));
    std::vector<spk_scene_layer> nine(9, layer(left, 256, 171, 1.0));
    check(spk_set_scene_layers(s, nine.data(), 9, nullptr, "x", nullptr) == SPK_ERR_INVALID_ARG, "nine layers are refused", spk_last_error(g_engine));
    spk_session_release(s);
    left->release(); right->release();
}

// --- gate 4: geometry -------------------------------------------------------------

// The fixture: S is 1500 x 1000, flat grey with a target rectangle R whose chroma differs
// (red up, blue down). The mask is R as well, baked at another size. The picture's edge
// (from a render without the layer) and the mask's (where the layer brightened the
// render) are found independently on the output, and compared row by row and column by
// column: the mask is cut by the engine's own geometry iff they coincide.
constexpr uint32_t kSW = 1500, kSH = 1000;
constexpr double kR[4] = {0.30, 0.28, 0.62, 0.66};   // x0, y0, x1, y1 in S
bool in_r(double s, double t) { return s >= kR[0] && s < kR[2] && t >= kR[1] && t < kR[3]; }

std::vector<float> target_source() {
    std::vector<float> f(size_t(kSW) * kSH * 3);
    for (uint32_t y = 0; y < kSH; ++y)
        for (uint32_t x = 0; x < kSW; ++x) {
            const bool in = in_r((x + 0.5) / kSW, (y + 0.5) / kSH);
            float* p = &f[3 * (size_t(y) * kSW + x)];
            p[0] = float(kMid * (in ? 1.5 : 1.0)); p[1] = float(kMid); p[2] = float(kMid * (in ? 0.6 : 1.0));
        }
    return f;
}

// The host's cut: pixel columns [x0, x0 + w) and rows [y0, y0 + h) of S, optionally mirrored left-right.
std::vector<float> host_cut(const std::vector<float>& src, uint32_t x0, uint32_t y0, uint32_t w, uint32_t h, bool mirror) {
    std::vector<float> f(size_t(w) * h * 3);
    for (uint32_t y = 0; y < h; ++y)
        for (uint32_t x = 0; x < w; ++x) {
            const uint32_t sx = mirror ? x0 + w - 1 - x : x0 + x;
            for (int c = 0; c < 3; ++c) f[3 * (size_t(y) * w + x) + size_t(c)] = src[3 * (size_t(y0 + y) * kSW + sx) + size_t(c)];
        }
    return f;
}

// The edge error between two binaries: each one's boundary as points (the midpoint between two
// neighbouring pixels that differ), and the symmetric Hausdorff distance between the two sets,
// in output pixels -- a distance normal to the edge, so a slanted edge (a straighten) is not
// read along a row, where half a pixel across it is eight along it at 7 degrees.
struct EdgeError { double max = 0; double mean = 0; size_t points = 0; };
EdgeError edge_error(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b, uint32_t w, uint32_t h) {
    auto boundary = [&](const std::vector<uint8_t>& m) {
        std::vector<std::pair<double, double>> pts;
        for (uint32_t y = 0; y < h; ++y)
            for (uint32_t x = 0; x < w; ++x) {
                const size_t i = size_t(y) * w + x;
                if (x + 1 < w && m[i] != m[i + 1]) pts.push_back({x + 1.0, y + 0.5});
                if (y + 1 < h && m[i] != m[i + w]) pts.push_back({x + 0.5, y + 1.0});
            }
        return pts;
    };
    const auto pa = boundary(a), pb = boundary(b);
    EdgeError e;
    e.points = pa.size();
    if (pa.empty() || pb.empty()) { e.max = 1e9; return e; }
    double sum = 0;
    auto directed = [&](const std::vector<std::pair<double, double>>& from, const std::vector<std::pair<double, double>>& to) {
        for (const auto& p : from) {
            double best = 1e18;
            for (const auto& q : to) best = std::min(best, (p.first - q.first) * (p.first - q.first) + (p.second - q.second) * (p.second - q.second));
            best = std::sqrt(best);
            e.max = std::max(e.max, best);
            sum += best;
        }
    };
    directed(pa, pb);
    directed(pb, pa);
    e.mean = sum / double(pa.size() + pb.size());
    return e;
}

struct GeoCase {
    std::string name;
    std::string geometry;          // wire fields
    bool host = false, mirror = false;
};

// One case's edge error (in output pixels). `f2s_override`, when given, is handed instead of the true matrix.
EdgeError geometry_case(const GeoCase& gc, MTL::Buffer* mask, uint32_t mw, uint32_t mh, const float* f2s_override = nullptr,
                        std::string* note = nullptr) {
    const std::vector<float> src = target_source();
    std::vector<float> frame = src;
    uint32_t w = kSW, h = kSH;
    float f2s[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    if (gc.host) {
        const uint32_t x0 = 225, y0 = 100, cw = 1125, ch = 700;
        frame = host_cut(src, x0, y0, cw, ch, gc.mirror);
        w = cw; h = ch;
        // frame (x, y) -> S: s = (x0 + x cw) / SW, mirrored s = (x0 + cw - x cw) / SW.
        f2s[0] = float((gc.mirror ? -1.0 : 1.0) * cw / kSW);
        f2s[2] = float((gc.mirror ? x0 + cw : x0) / double(kSW));
        f2s[4] = float(double(ch) / kSH);
        f2s[5] = float(double(y0) / kSH);
    }
    const std::string sep = gc.geometry.empty() ? "" : ", ";
    const std::string extra = "\"halation_active\": false" + sep + gc.geometry;
    // Four develops of the same cut: the picture (a), the picture under the mask (b), the picture
    // under a full plane at coverage 0.5 (h: the lift where k = 0.5, pixel by pixel), and a frame of
    // the target's two colours mixed half and half (m: the chroma where the picture's own
    // interpolation weight is 0.5). Each edge is then "weight > 0.5" on its own signal, so neither
    // threshold leans with the film's curve.
    std::vector<float> mix(frame.size());
    for (size_t i = 0; i < mix.size(); i += 3) { mix[i] = float(kMid * 1.25); mix[i + 1] = float(kMid); mix[i + 2] = float(kMid * 0.8); }
    MTL::Buffer* full = full_plane();
    spk_session* a = open(frame, w, h, base_delta(extra));
    spk_session* b = open(frame, w, h, base_delta(extra + ", \"scene_layers\": \"geo\""));
    spk_session* hs = open(frame, w, h, base_delta(extra + ", \"scene_layers\": \"half\""));
    spk_session* ms = open(mix, w, h, base_delta(extra));
    hand(b, {layer(mask, mw, mh, 1.5)}, "geo", f2s_override ? f2s_override : f2s);
    hand(hs, {layer(full, 4, 4, 1.5, 0.5)}, "half", f2s);
    Frame fa, fb, fh, fm;
    const bool rendered = render(a, fa) == SPK_OK && render(b, fb) == SPK_OK && render(hs, fh) == SPK_OK &&
                          render(ms, fm) == SPK_OK && fa.w == fb.w && fa.h == fb.h && fa.w == fh.w && fa.h == fh.h;
    if (!rendered) {
        if (note) *note = std::string("a render failed: ") + spk_last_error(g_engine);
        spk_session_release(a); spk_session_release(b); spk_session_release(hs); spk_session_release(ms);
        full->release();
        EdgeError e;
        e.max = 1e9;
        return e;
    }
    spk_session_release(a); spk_session_release(b); spk_session_release(hs); spk_session_release(ms);
    full->release();
    const uint32_t ow = fa.w, oh = fa.h;
    const double cm = (fm.at(ow / 2, oh / 2, 0) + 1.0) / (fm.at(ow / 2, oh / 2, 2) + 1.0);
    std::vector<uint8_t> T(size_t(ow) * oh), M(size_t(ow) * oh);
    size_t nt = 0, nm = 0;
    for (size_t i = 0; i < T.size(); ++i) {
        T[i] = (fa.px[3 * i] + 1.0) / (fa.px[3 * i + 2] + 1.0) > cm;
        // Lifted, and by more than half: where S ends inside the cut (a straighten's corners) the
        // half-coverage frame's own edge leaves an unsharp undershoot beside it, which a lone
        // "b > h" would read as mask.
        M[i] = fb.px[3 * i + 1] > fh.px[3 * i + 1] && fb.px[3 * i + 1] > fa.px[3 * i + 1];
        nt += T[i]; nm += M[i];
    }
    if (note) *note = fmt("%u x %u, target %zu px, mask %zu px", ow, oh, nt, nm);
    if (const char* dump = std::getenv("SLC_DUMP")) {
        static int counter = 0;
        FILE* f = std::fopen(fmt("%s.%02d.pgm", dump, counter++).c_str(), "wb");
        std::fprintf(f, "P5 %u %u 255\n", ow, oh);
        for (size_t i = 0; i < T.size(); ++i) std::fputc(T[i] * 100 + M[i] * 155, f);
        std::fclose(f);
    }
    return edge_error(T, M, ow, oh);
}

std::vector<GeoCase> geometry_cases() {
    const std::string crop = R"("geometry_crop_x": 0.1, "geometry_crop_y": 0.05, "geometry_crop_w": 0.8, "geometry_crop_h": 0.85)";
    return {
        {"identity", ""},
        {"engine crop", crop},
        {"crop + straighten 7 deg", crop + R"(, "geometry_rotation_deg": 7.0)"},
        {"quarter turn 1", R"("geometry_quarter_turns": 1)"},
        {"quarter turns 2", R"("geometry_quarter_turns": 2)"},
        {"quarter turns 3", R"("geometry_quarter_turns": 3)"},
        {"flip h + flip v", R"("geometry_flip_h": true, "geometry_flip_v": true)"},
        {"crop + straighten -5 + turn 1 + flip h", crop + R"(, "geometry_rotation_deg": -5.0, "geometry_quarter_turns": 1, "geometry_flip_h": true)"},
        {"host cut (frame_to_source != I)", "", true, false},
        {"host cut + engine straighten 4 + turn 3", R"("geometry_rotation_deg": 4.0, "geometry_quarter_turns": 3)", true, false},
        {"host cut, mirrored + engine flip v", R"("geometry_flip_v": true)", true, true},
    };
}

void gate4() {
    std::printf("\n== gate 4: the mask's edge through the engine's cut and a host cut, within one pixel ==\n");
    // A hard-edged mask of R at half the frame's size, 750 x 500: R's edges fall on its texel
    // boundaries as on the frame's pixel boundaries, so the two edges are the same line in S and
    // what is measured is the mapping. Then at 1024 x 683, where the plane's own texels move its
    // edge by up to half a texel (0.73 frame px): the canonical plane's quantisation, reported.
    uint32_t mw = 750, mh = 500;
    MTL::Buffer* mask = plane(mw, mh, [](double s, double t) { return in_r(s, t) ? 1.0 : 0.0; });
    for (int pass = 0; pass < 2; ++pass) {
        if (pass == 1) {
            mask->release();
            mw = 1024; mh = 683;
            mask = plane(mw, mh, [](double s, double t) { return in_r(s, t) ? 1.0 : 0.0; });
        }
        for (const GeoCase& gc : geometry_cases()) {
            std::string note;
            const EdgeError e = geometry_case(gc, mask, mw, mh, nullptr, &note);
            check(e.max <= 1.0 && e.points > 0, fmt("plane %ux%u: %s", mw, mh, gc.name.c_str()),
                  fmt("edge distance max %.2f px, mean %.3f px over %zu boundary points; %s", e.max, e.mean, e.points, note.c_str()));
        }
    }
    mask->release();
    mw = 750; mh = 500;
    mask = plane(mw, mh, [](double s, double t) { return in_r(s, t) ? 1.0 : 0.0; });

    std::printf("\n== gate 4's self-test: each term broken goes red ==\n");
    const std::vector<GeoCase> cases = geometry_cases();
    const GeoCase& combined = cases[7];
    for (const char* term : {"crop_x", "crop_y", "scale_x", "scale_y", "rotation", "turns", "flip_h", "flip_v"}) {
        setenv("SPK_SCENE_LAYERS_BREAK", term, 1);
        const EdgeError e = geometry_case(combined, mask, mw, mh);
        unsetenv("SPK_SCENE_LAYERS_BREAK");
        check(e.max > 1.0, fmt("the engine's cut, %s broken for the mask alone: red", term), fmt("edge distance max %.1f px, mean %.2f", e.max, e.mean));
    }
    const GeoCase& host = cases[9];
    const uint32_t x0 = 225, y0 = 100, cw = 1125, ch = 700;
    const float truth[9] = {float(double(cw) / kSW), 0, float(double(x0) / kSW), 0, float(double(ch) / kSH), float(double(y0) / kSH), 0, 0, 1};
    for (int k = 0; k < 9; ++k) {
        float broken[9];
        std::memcpy(broken, truth, sizeof broken);
        broken[k] += 0.01f;
        const EdgeError e = geometry_case(host, mask, mw, mh, broken);
        check(e.max > 1.0, fmt("frame_to_source[%d] + 0.01: red", k), fmt("edge distance max %.1f px, mean %.2f", e.max, e.mean));
    }
    const float identity[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    const EdgeError e = geometry_case(host, mask, mw, mh, identity);
    check(e.max > 1.0, "a host cut handed as the identity: red", fmt("edge distance max %.1f px, mean %.2f", e.max, e.mean));
    mask->release();
}

// --- gate 5: one negative ----------------------------------------------------------

// The grain's standard deviation per column bin, in output counts (green), with each
// column's own mean removed first so the exposure ramp is not counted as grain.
std::vector<double> column_sigma(const Frame& f, uint32_t x0, uint32_t x1, uint32_t bin, uint32_t y0, uint32_t y1) {
    std::vector<double> out;
    for (uint32_t b = x0; b + bin <= x1; b += bin) {
        double ss = 0;
        size_t n = 0;
        for (uint32_t x = b; x < b + bin; ++x) {
            double m = 0;
            for (uint32_t y = y0; y < y1; ++y) m += f.at(x, y, 1);
            m /= double(y1 - y0);
            for (uint32_t y = y0; y < y1; ++y) { const double d = f.at(x, y, 1) - m; ss += d * d; ++n; }
        }
        out.push_back(std::sqrt(ss / double(n)));
    }
    return out;
}

void gate5() {
    std::printf("\n== gate 5: one negative -- the grain across a soft edge is the grain of the exposure there ==\n");
    const uint32_t W = 2400, H = 1600;
    std::vector<float> grey(size_t(W) * H * 3, float(kMid));
    const double e = 1.5;
    // A linear ramp of k from 0 at s = 0.3 to 1 at s = 0.7 (960 px), +1.5 stops at full coverage.
    MTL::Buffer* ramp = plane(4096, 2731, [](double s, double) { return (s - 0.3) / 0.4; });
    const auto develop = [&](const std::string& extra, bool layered, int seed) {
        std::string d = base_delta(std::string(R"("grain_active": true, "halation_active": false, )") + fmt("\"grain_seed\": %d", seed) +
                                   (extra.empty() ? "" : ", " + extra) + (layered ? ", \"scene_layers\": \"ramp\"" : ""));
        spk_session* s = open(grey, W, H, d);
        if (layered) hand(s, {layer(ramp, 4096, 2731, e)}, "ramp");
        Frame f;
        render(s, f);
        spk_session_release(s);
        return f;
    };
    const Frame B = develop("", true, 11);
    const uint32_t bin = 48, x0 = uint32_t(0.3 * W), x1 = uint32_t(0.7 * W), y0 = 100, y1 = H - 100;
    const std::vector<double> sb = column_sigma(B, x0, x1, bin, y0, y1);
    // Uniform developments at the exposures the ramp passes through, q in 0 ... 1; q = 0.5 is the edge's mean.
    const int Q = 9;
    std::vector<double> sq(Q), meanq(Q);
    double split_noise = 0;
    for (int i = 0; i < Q; ++i) {
        const double q = double(i) / (Q - 1);
        const Frame U = develop(fmt("\"exposure_compensation_ev\": %.17g", q * e), false, 11);
        const std::vector<double> s = column_sigma(U, x0, x1, bin, y0, y1);
        double m = 0;
        for (double v : s) m += v;
        m /= double(s.size());
        sq[size_t(i)] = m;
        for (double v : s) split_noise = std::max(split_noise, std::fabs(v / m - 1.0));
        double mu = 0;
        for (uint32_t y = y0; y < y1; ++y) mu += U.at(W / 2, y, 1);
        meanq[size_t(i)] = mu / double(y1 - y0);
    }
    // Predicted sigma at a bin: the uniform develop's at that bin's exposure, interpolated in q.
    double worst = 0, worst_step = 0;
    std::vector<double> rel;
    for (size_t j = 0; j < sb.size(); ++j) {
        const double q = ((x0 + j * bin + bin / 2.0) / W - 0.3) / 0.4;
        const double u = std::clamp(q, 0.0, 1.0) * (Q - 1);
        const size_t i0 = std::min(size_t(u), size_t(Q - 2));
        const double t = u - double(i0);
        const double pred = sq[i0] + (sq[i0 + 1] - sq[i0]) * t;
        rel.push_back(sb[j] / pred - 1.0);
        worst = std::max(worst, std::fabs(rel.back()));
        if (j) worst_step = std::max(worst_step, std::fabs(rel[j] - rel[j - 1]));
    }
    std::printf("      sigma (counts) of the uniform develops, q = 0 ... 1 (0.5 = the edge's mean):");
    for (double v : sq) std::printf(" %.1f", v);
    std::printf("\n      their means at the centre column:");
    for (double v : meanq) std::printf(" %.0f", v);
    std::printf("\n      across the edge, sigma / sigma(exposure) - 1, per %u-px bin:", bin);
    for (double v : rel) std::printf(" %+.3f", v);
    std::printf("\n");
    check(worst <= 2.0 * split_noise + 0.01,
          "no step in the grain's sigma across the edge beyond what the exposure explains",
          fmt("max |sigma/sigma(exposure) - 1| = %.4f, max bin-to-bin step %.4f; the uniform develops' own bin-to-bin spread %.4f",
              worst, worst_step, split_noise));
    // What the statistic sees in the design RFC-052 rejected (§2.1): two developments blended
    // across the edge, the second a different realisation of the grain.
    const Frame U0 = develop("", false, 11), U1 = develop(fmt("\"exposure_compensation_ev\": %.17g", e), false, 23);
    Frame blend = U0;
    for (uint32_t y = 0; y < H; ++y)
        for (uint32_t x = 0; x < W; ++x) {
            const double k = std::clamp(((x + 0.5) / W - 0.3) / 0.4, 0.0, 1.0);
            for (int c = 0; c < 3; ++c) {
                const size_t i = 3 * (size_t(y) * W + x) + size_t(c);
                blend.px[i] = uint16_t(std::lround(U0.px[i] * (1 - k) + U1.px[i] * k));
            }
        }
    const std::vector<double> sbl = column_sigma(blend, x0, x1, bin, y0, y1);
    double blend_worst = 0;
    for (size_t j = 0; j < sbl.size(); ++j) {
        const double q = ((x0 + j * bin + bin / 2.0) / W - 0.3) / 0.4;
        const double u = std::clamp(q, 0.0, 1.0) * (Q - 1);
        const size_t i0 = std::min(size_t(u), size_t(Q - 2));
        const double pred = sq[i0] + (sq[i0 + 1] - sq[i0]) * (u - double(i0));
        blend_worst = std::max(blend_worst, std::fabs(sbl[j] / pred - 1.0));
    }
    check(blend_worst > 2.0 * split_noise + 0.01, "the same statistic on two developments blended (the rejected design): red",
          fmt("max |sigma/sigma(exposure) - 1| = %.4f", blend_worst));
    ramp->release();
}

// --- §11: the paths the RFC did not look at in code ------------------------------------

void other_paths() {
    std::printf("\n== RFC-052 §11: the Digital Intermediate, the HDR session curve, a slide ==\n");
    const uint32_t W = 900, H = 600;
    const std::vector<float> frame = ramp_frame(W, H);
    MTL::Buffer* full = full_plane();
    const double e = 1.0;
    // The DI reads the session's negative, so a full-mask layer is Film Exposure + e there too.
    {
        spk_session* a = open(frame, W, H, base_delta(fmt("\"exposure_compensation_ev\": %.17g", e)));
        spk_session* b = open(frame, W, H, base_delta("\"scene_layers\": \"di\""));
        hand(b, {layer(full, 4, 4, e)}, "di");
        spk_result ra{}, rb{};
        char* ja = nullptr; char* jb = nullptr;
        const spk_status sa = spk_render_digital_intermediate(a, &ra, &ja), sb = spk_render_digital_intermediate(b, &rb, &jb);
        Frame fa, fb;
        auto take = [](const spk_result& r, Frame& f) {
            f.w = r.width; f.h = r.height; f.px.resize(size_t(r.width) * r.height * 3);
            for (uint32_t y = 0; y < r.height; ++y) for (uint32_t x = 0; x < r.width; ++x) for (int c = 0; c < 3; ++c)
                f.px[3 * (size_t(y) * r.width + x) + size_t(c)] = r.rgba16[4 * (size_t(y) * r.row_stride_px + x) + size_t(c)];
        };
        if (sa == SPK_OK) take(ra, fa);
        if (sb == SPK_OK) take(rb, fb);
        if (ja) spk_string_free(ja);
        if (jb) spk_string_free(jb);
        spk_result_free(&ra); spk_result_free(&rb);
        check(sa == SPK_OK && sb == SPK_OK && diff(fa, fb).max <= 2.0, "Digital Intermediate: a full-mask +1 layer = Film Exposure +1",
              describe(diff(fa, fb)));
        spk_session_release(a); spk_session_release(b);
    }
    // The HDR session curve is measured on the medium (the probe), which has no layers: the
    // same reply with and without a set, and no refusal for the stamp the probe drops.
    {
        spk_session* a = open(frame, W, H, base_delta());
        spk_session* b = open(frame, W, H, base_delta("\"scene_layers\": \"hdr\""));
        hand(b, {layer(full, 4, 4, 2.0)}, "hdr");
        char* ja = nullptr; char* jb = nullptr;
        const spk_status sa = spk_session_hdr_curve(a, nullptr, &ja), sb = spk_session_hdr_curve(b, nullptr, &jb);
        const std::string ta = ja ? ja : "", tb = jb ? jb : "";
        if (ja) spk_string_free(ja);
        if (jb) spk_string_free(jb);
        check(sa == SPK_OK && sb == SPK_OK && ta == tb, "HDR session curve: the same reply under a +2 full-mask layer",
              fmt("%zu bytes each; status %d / %d", ta.size(), sa, sb));
        spk_session_release(a); spk_session_release(b);
    }
    // A slide's scan, and its HDR scan (API-SPEC §19.1).
    for (const char* hdr : {"", ", \"scan_hdr_headroom\": 4.0, \"scan_hdr_output_scale\": 0.25"}) {
        const std::string slide = std::string(R"("film_stock": "fujifilm_provia_100f", "scan_film": true)") + hdr;
        const std::string d = R"("print_stock": "kodak_portra_endura", "product_defaults": true, "grain_active": false, "glare_active": false, "auto_exposure": false, )";
        spk_session* a = open(frame, W, H, "{" + d + slide + fmt(", \"exposure_compensation_ev\": %.17g}", e));
        spk_session* b = open(frame, W, H, "{" + d + slide + ", \"scene_layers\": \"slide\"}");
        hand(b, {layer(full, 4, 4, e)}, "slide");
        Frame fa, fb;
        const bool ok = render(a, fa) == SPK_OK && render(b, fb) == SPK_OK;
        check(ok && diff(fa, fb).max <= 2.0, fmt("slide scan%s: a full-mask +1 layer = Film Exposure +1", *hdr ? " (HDR, headroom 4)" : ""),
              describe(diff(fa, fb)));
        spk_session_release(a); spk_session_release(b);
    }
    // A film edge (RFC-032): the node is before `overscan`, so the rebate, the holes and the edge print are
    // not the layer's. A full-mask +1 layer against Exp. Comp. +1 (which moves the picture's exposure only),
    // and the canvas outside the picture's gate against the same canvas without the layer.
    {
        // Halation off, so the figure below is not the halo: with it on, the brighter picture's halo reaches
        // the rebate, under Exp. Comp. as under the layer (28 counts 2 % past the gate, measured).
        const std::string edge = R"("overscan_active": true, "overscan_format": "135", "overscan_edge_text": "KODAK 400", "overscan_frame_seed": 3, "overscan_camera_seed": 5, "halation_active": false)";
        spk_session* a = open(frame, W, H, base_delta(edge + fmt(", \"exposure_compensation_ev\": %.17g", e)));
        spk_session* b = open(frame, W, H, base_delta(edge + ", \"scene_layers\": \"edge\""));
        spk_session* n = open(frame, W, H, base_delta(edge));
        MTL::Buffer* none = plane(64, 48, [](double, double) { return 0.0; });
        hand(b, {layer(full, 4, 4, e)}, "edge");
        Frame fa, fb, fn;
        const bool ok = render(a, fa) == SPK_OK && render(b, fb) == SPK_OK && render(n, fn) == SPK_OK;
        check(ok && fb.w > W && diff(fa, fb).max <= 2.0, "film edge: a full-mask +1 layer = Film Exposure +1 on the whole canvas",
              fmt("canvas %u x %u; %s", fb.w, fb.h, describe(diff(fa, fb)).c_str()));
        // The rebate's rows above and below the picture: untouched by a layer.
        char* g = nullptr;
        spk_overscan_geometry(b, &g);
        spk::Json geo = parse(g);
        double t0 = 1, t1 = 0;
        if (!geo.at("gates").items().empty()) {
            const auto& q = geo.at("gates").items()[0].items();
            for (size_t k = 1; k < q.size(); k += 2) { t0 = std::min(t0, q[k].as_double()); t1 = std::max(t1, q[k].as_double()); }
        }
        double outside = 0;
        size_t rows = 0;
        for (uint32_t y = 0; y < fb.h; ++y) {
            const double t = (y + 0.5) / fb.h;
            if (t > t0 - 0.04 && t < t1 + 0.04) continue;   // the gate, its penumbra, and the picture's own spill past it
            ++rows;
            for (uint32_t x = 0; x < fb.w; ++x)
                for (int c = 0; c < 3; ++c) outside = std::max(outside, std::fabs(fb.at(x, y, c) - fn.at(x, y, c)));
        }
        // Reported, not held: the rebate is the same under the layer as under Exp. Comp. (the canvases are
        // equal above); what Exp. Comp. itself moves there, past the gate's penumbra, is the engine's as it is.
        std::printf("      film edge: past the gate (rows outside %.3f-%.3f by 4 %% of the canvas, %zu rows), the layer moved the "
                    "rebate by at most %.0f counts, as Exp. Comp. +1 does (equal canvases)\n", t0, t1, rows, outside);
        none->release();
        spk_session_release(a); spk_session_release(b); spk_session_release(n);
    }
    full->release();
}

#endif  // SPK_BASELINE

// --- gate 2 against another build: hashes with the old surface only ------------------------

void hashes() {
    const uint32_t W = 1200, H = 800;
    const std::vector<float> frame = ramp_frame(W, H);
    for (const NeutralCase& cfg : kNeutralConfigs) {
        spk_session* s = open(frame, W, H, base_delta(neutral_extra(cfg)));
        Frame f;
        render(s, f);
        Frame l;
        render(s, l, "live");
        std::printf("%-40s full %s  live %s\n", cfg.name, sha256(f).c_str(), sha256(l).c_str());
        spk_session_release(s);
    }
}

#ifndef SPK_BASELINE
// --- gate 6: cost ----------------------------------------------------------------------------

uint64_t footprint(bool peak) {
    task_vm_info_data_t info{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) return 0;
    return peak ? info.ledger_phys_footprint_peak : info.phys_footprint;
}

void cost(uint32_t W, uint32_t H, uint32_t n) {
    std::vector<float> frame(size_t(W) * H * 3);
    for (uint32_t y = 0; y < H; ++y)
        for (uint32_t x = 0; x < W; ++x)
            for (int c = 0; c < 3; ++c)
                frame[3 * (size_t(y) * W + x) + size_t(c)] = float(kMid * std::pow(2.0, -6.0 + 10.0 * (x + 0.5) / W) * (0.7 + 0.3 * c * (y + 0.5) / H));
    // Planes at RFC-052 §4.4's canonical size for this source: long edge min(4096, L).
    const uint32_t L = std::max(W, H), pl = std::min(4096u, L);
    const uint32_t pw = W >= H ? pl : uint32_t(std::lround(double(pl) * W / H)), ph = W >= H ? uint32_t(std::lround(double(pl) * H / W)) : pl;
    std::vector<MTL::Buffer*> planes;
    std::vector<spk_scene_layer> ls;
    for (uint32_t i = 0; i < n; ++i) {
        const double cx = 0.2 + 0.6 * i / std::max(1u, n), cy = 0.5;
        planes.push_back(plane(pw, ph, [&](double s, double t) {
            const double d = std::hypot((s - cx) * W / L, (t - cy) * H / L);
            return 1.0 - std::clamp((d - 0.15) / 0.1, 0.0, 1.0);
        }));
        ls.push_back(layer(planes.back(), pw, ph, i % 2 ? -1.0 : 1.0));
    }
    const uint64_t base = footprint(false);
    const std::string stamp = fmt("n%u", n);
    const std::string wire = n ? fmt(", \"scene_layers\": \"%s\"", stamp.c_str()) : "";
    spk_session* s = open(frame, W, H, "{" + std::string(R"("film_stock": "kodak_portra_400", "print_stock": "kodak_portra_endura", "product_defaults": true, "glare_active": false, "auto_exposure": false, "preview_long_edge": 2400)") + wire + "}");
    double set_ms = 0;
    if (n) {
        const auto t0 = std::chrono::steady_clock::now();
        hand(s, ls, stamp.c_str());
        set_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    }
    spk_result r{};
    auto timed = [&](const char* tier) {
        const auto t0 = std::chrono::steady_clock::now();
        if (spk_render(s, tier, &r) != SPK_OK) { std::printf("render failed: %s\n", spk_last_error(g_engine)); std::exit(2); }
        const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        const std::string id = r.progress_id;
        spk_result_free(&r);
        std::snprintf(r.progress_id, sizeof r.progress_id, "%s", id.c_str());
        return ms;
    };
    const double full1 = timed("full");
    const double full2 = timed("full");   // the film side again, the session warm: a develop when the pointer rests at Full
    // The node by itself, from the engine's own timer, when the run asks for it (SPEKTRALAB_NODE_TIMINGS
    // serialises every node, so the develop times above are taken without it).
    double node_ms = -1;
    if (std::getenv("SPEKTRALAB_NODE_TIMINGS")) {
        char* out = nullptr;
        spk_progress(s, r.progress_id, &out);
        node_ms = parse(out).at("node_times").at("filming.expose.scene_layers").as_double(0.0);
    }
    const double live1 = timed("live");
    const double live2 = timed("live");
    // A stroke: a new stamp on the wire (a pipeline rebuild) and a new set, then the live develop.
    double stroke_ms = 0, stroke_live = 0;
    if (n) {
        const auto t0 = std::chrono::steady_clock::now();
        set_params(s, "{\"scene_layers\": \"stroke\"}");
        hand(s, ls, "stroke");
        stroke_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        stroke_live = timed("live");
    }
    const uint64_t peak = footprint(true);
    std::printf("cost %ux%u layers %u: full %.0f / again %.0f ms, live %.0f / again %.0f ms, set %.1f ms, stroke (set_params + set) %.1f ms then live %.0f ms; "
                "peak phys_footprint %.0f MB (process before open %.0f MB); planes %.0f MB%s\n",
                W, H, n, full1, full2, live1, live2, set_ms, stroke_ms, stroke_live, peak / 1048576.0, base / 1048576.0,
                double(n) * pw * ph * 2 / 1048576.0, node_ms >= 0 ? fmt("; the node alone at Full %.1f ms", node_ms).c_str() : "");
    spk_session_release(s);
    for (MTL::Buffer* b : planes) b->release();
}
#endif

}  // namespace

int main(int argc, char** argv) {
    if (argc < 3) { std::fprintf(stderr, "usage: scene_layers_checks <resources> gates|hashes|cost W H N\n"); return 2; }
    auto pool = NS::TransferPtr(NS::AutoreleasePool::alloc()->init());
    g_device = MTL::CreateSystemDefaultDevice();
    g_engine = spk_engine_create(argv[1], g_device);
    if (!g_engine) { std::fprintf(stderr, "engine: %s\n", spk_last_error(nullptr)); return 2; }
    const std::string mode = argv[2];
    const auto started = std::chrono::steady_clock::now();
    if (mode == "hashes") hashes();
#ifndef SPK_BASELINE
    else if (mode == "gates") {
        const std::string only = argc > 3 ? argv[3] : "";
        if (only.empty() || only == "1") gate1();
        if (only.empty() || only == "2") gate2();
        if (only.empty() || only == "3") gate3();
        if (only.empty() || only == "stamp") stamp_and_negative();
        if (only.empty() || only == "4") gate4();
        if (only.empty() || only == "5") gate5();
        if (only.empty() || only == "paths") other_paths();
        std::printf("\n%d failed, %.1f s\n", failures, std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count());
    } else if (mode == "cost" && argc == 6) cost(uint32_t(std::atoi(argv[3])), uint32_t(std::atoi(argv[4])), uint32_t(std::atoi(argv[5])));
#endif
    else { std::fprintf(stderr, "unknown mode\n"); return 2; }
    spk_engine_destroy(g_engine);
    g_device->release();
    return failures ? 1 : 0;
}
