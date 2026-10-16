// spk_qt_postdev: Post-Dev (Layer 2) -- src/PostDev.{hpp,cpp}. No RAW, no
// engine, no shown window.
//   --cpu    the model and its ranges, the uniforms, the curve against a
//            transcription of CurveMath.swift, the CPU path against a
//            double-precision transcription of Shaders.metal, identity,
//            determinism across thread counts, JSON, the wheel, and the
//            std140 block's order.
//   --bench [width height]   CPU timing (default 7008 x 4672, 32.7 MP).
#include "PostDev.hpp"
#include <QColorSpace>
#include <QGuiApplication>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <functional>
#include <limits>
#include <memory>
#include <random>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace pd = spk::desktop::postdev;
namespace {

int checks = 0;
void check(bool value, const std::string& message) {
    ++checks;
    if (!value) throw std::runtime_error(message);
}
void rejects(const std::function<void()>& action, const std::string& message) {
    try { action(); } catch (const std::exception&) { ++checks; return; }
    throw std::runtime_error("accepted: " + message);
}
std::string fmt(const char* format, double a, double b = 0, double c = 0) {
    char buffer[160];
    std::snprintf(buffer, sizeof buffer, format, a, b, c);
    return buffer;
}

// The inputs do not depend on the STL's distributions.
struct Random {
    std::mt19937 gen;
    explicit Random(unsigned seed) : gen(seed) {}
    double uniform() { return double(gen()) / 4294967296.0; }
    double range(double low, double high) { return low + (high - low) * uniform(); }
};

// ---------------------------------------------------------------------------
// The oracle. Written from the Swift and Metal sources, not from PostDev.cpp:
// the uniforms as Adjustments.swift:72-94 and Mask.swift:301-324 derive them
// (in Float, as Swift does), the spline as CurveMath.swift:106-137 evaluates
// it (CGFloat is Double), and the kernel (Shaders.metal:119-147, 270-403) in
// double -- with Metal's float literals as the floats they are, the literal
// pow(pow(c, 2.2) * gain, 1/2.2), and the linear sampler's texel-centre
// addressing with exact weights.
// ---------------------------------------------------------------------------
using D3 = std::array<double, 3>;

double macEvaluate(const std::vector<pd::CurvePoint>& points, double x) {
    const size_t n = points.size();
    if (n < 2) return x;
    if (x <= points[0].x) return points[0].y;
    if (x >= points[n - 1].x) return points[n - 1].y;
    std::vector<double> d(n - 1, 0.0);
    for (size_t i = 0; i < n - 1; ++i) {
        double dx = std::max(points[i + 1].x - points[i].x, 1e-6);
        d[i] = (points[i + 1].y - points[i].y) / dx;
    }
    std::vector<double> m(n, 0.0);
    m[0] = d[0];
    m[n - 1] = d[n - 2];
    for (size_t i = 1; i < n - 1; ++i) m[i] = (d[i - 1] * d[i] <= 0) ? 0 : (d[i - 1] + d[i]) / 2;
    for (size_t i = 0; i < n - 1; ++i) {
        if (!(d[i] != 0)) continue;
        double a = m[i] / d[i], b = m[i + 1] / d[i];
        double s = a * a + b * b;
        if (s > 9) {
            double t = 3 / std::sqrt(s);
            m[i] = t * a * d[i];
            m[i + 1] = t * b * d[i];
        }
    }
    size_t i = 0;
    while (i < n - 2 && x > points[i + 1].x) i += 1;
    double h = std::max(points[i + 1].x - points[i].x, 1e-6);
    double t = (x - points[i].x) / h;
    double t2 = t * t, t3 = t2 * t;
    double h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t;
    double h01 = -2 * t3 + 3 * t2, h11 = t3 - t2;
    double y = h00 * points[i].y + h10 * h * m[i] + h01 * points[i + 1].y + h11 * h * m[i + 1];
    return std::min(std::max(y, 0.0), 1.0);
}

struct MacUniforms {
    float wb[3];
    float exposureGain;
    float contrast, brightness, saturation, highlights, shadows, blackPoint, whitePoint;
    float cbMaster[3], cbShadows[3], cbMidtones[3], cbHighlights[3], cbLum[4];
    float vignetteAmount, vignetteMidpoint, midGrey;
    bool curvesActive, enabled;
};

void macZone(const pd::ColorZone& z, float out[3]) {
    const double pi = 3.141592653589793; // Double.pi
    double h = z.hue * pi / 180;
    double r = std::cos(h), g = std::cos(h - 2 * pi / 3), b = std::cos(h + 2 * pi / 3);
    float s = float(z.saturation) * float(0.25);
    out[0] = float(r) * s;
    out[1] = float(g) * s;
    out[2] = float(b) * s;
}

bool macIdentityCurve(const pd::Curve& c) {
    return c.points.size() == 2 && c.points[0].x == 0 && c.points[0].y == 0 && c.points[1].x == 1 &&
           c.points[1].y == 1;
}

MacUniforms macUniforms(const pd::Params& a, float midGrey) {
    MacUniforms u{};
    const float t = float(a.temperature) / float(100), g = float(a.tint) / float(100);
    u.wb[0] = float(1) + float(0.18) * t;
    u.wb[1] = float(1) - float(0.12) * g;
    u.wb[2] = float(1) - float(0.18) * t;
    u.exposureGain = float(std::pow(2.0, a.exposure));
    u.contrast = float(a.contrast) / float(100);
    u.brightness = float(a.brightness) / float(100);
    u.saturation = float(1) + float(a.saturation) / float(100);
    u.highlights = float(a.highlights) / float(100);
    u.shadows = float(a.shadows) / float(100);
    u.blackPoint = float(a.blackPoint) / float(100);
    u.whitePoint = float(a.whitePoint) / float(100);
    u.midGrey = midGrey;
    macZone(a.colorBalance.master, u.cbMaster);
    macZone(a.colorBalance.shadows, u.cbShadows);
    macZone(a.colorBalance.midtones, u.cbMidtones);
    macZone(a.colorBalance.highlights, u.cbHighlights);
    u.cbLum[0] = float(a.colorBalance.master.luminance) * float(0.25);
    u.cbLum[1] = float(a.colorBalance.shadows.luminance) * float(0.25);
    u.cbLum[2] = float(a.colorBalance.midtones.luminance) * float(0.25);
    u.cbLum[3] = float(a.colorBalance.highlights.luminance) * float(0.25);
    u.vignetteAmount = float(a.vignette.amount) / float(100);
    u.vignetteMidpoint = float(a.vignette.midpoint) / float(100);
    const auto& c = a.curves;
    u.curvesActive = !(macIdentityCurve(c.rgb) && macIdentityCurve(c.luma) && macIdentityCurve(c.red) &&
                       macIdentityCurve(c.green) && macIdentityCurve(c.blue));
    u.enabled = a.enabled;
    return u;
}

std::vector<float> macTables(const pd::CurveSet& c) {
    std::vector<float> out;
    for (const pd::Curve* curve : {&c.rgb, &c.luma, &c.red, &c.green, &c.blue})
        for (int i = 0; i < 256; ++i) out.push_back(float(macEvaluate(curve->points, double(i) / double(255))));
    return out;
}

struct Oracle {
    MacUniforms u;
    std::vector<float> tables;

    static double f(float v) { return double(v); } // a Metal float literal, exactly
    static double saturate(double v) { return std::min(std::max(v, 0.0), 1.0); }
    static double luma(const D3& c) { return c[0] * f(0.2126f) + c[1] * f(0.7152f) + c[2] * f(0.0722f); }
    static double tonePosition(double l, double midGrey) {
        double m = saturate(midGrey);
        if (m <= 0.0 || m >= 1.0) m = 0.5;
        return (l <= m) ? 0.5 * l / m : 0.5 + 0.5 * (l - m) / (1.0 - m);
    }
    D3 tone(D3 c) const {
        const double mg = u.midGrey;
        for (int i = 0; i < 3; ++i) c[i] *= u.wb[i];
        if (u.exposureGain != 1.0f)
            for (auto& v : c) v = std::pow(std::pow(std::max(v, 0.0), f(2.2f)) * u.exposureGain, f(1.0f / 2.2f));
        if (u.contrast != 0.0f) {
            double k = 1.0 + u.contrast * f(1.2f);
            for (auto& v : c) v = (v - mg) * k + mg;
        }
        if (u.brightness != 0.0f)
            for (auto& v : c) v = std::pow(std::max(v, 0.0), 1.0 / (1.0 + u.brightness * f(0.8f)));
        double l = tonePosition(luma(c), mg);
        if (u.shadows != 0.0f) {
            double w = (1.0 - l);
            w = w * w;
            for (auto& v : c) v += u.shadows * 0.25 * w * (1.0 - v);
        }
        if (u.highlights != 0.0f) {
            double w = l * l;
            for (auto& v : c) v += u.highlights * 0.25 * w * (u.highlights > 0 ? (1.0 - v) : v);
        }
        for (auto& v : c)
            v = (v - u.blackPoint) / std::max(1.0 - u.blackPoint - u.whitePoint, f(0.05f));
        l = luma(c);
        for (auto& v : c) v = l + (v - l) * u.saturation;
        double ls = saturate(tonePosition(l, mg));
        double wS = (1.0 - ls) * (1.0 - ls);
        double wH = ls * ls;
        double wM = std::max(1.0 - wS - wH, 0.0);
        for (int i = 0; i < 3; ++i)
            c[i] += u.cbMaster[i] + u.cbShadows[i] * wS + u.cbMidtones[i] * wM + u.cbHighlights[i] * wH;
        double lum = 1.0 + u.cbLum[0] + u.cbLum[1] * wS + u.cbLum[2] * wM + u.cbLum[3] * wH;
        for (auto& v : c) v *= lum;
        return c;
    }
    // table.sample(linear, clamp_to_edge, normalised) on a 256-wide row.
    double lookup(int row, double x) const {
        double texel = x * 256.0 - 0.5;
        double i0 = std::floor(texel);
        double w = texel - i0;
        int a = std::clamp(int(i0), 0, 255), b = std::clamp(int(i0) + 1, 0, 255);
        return tables[size_t(row * 256 + a)] * (1.0 - w) + tables[size_t(row * 256 + b)] * w;
    }
    D3 pixel(D3 c, double ux, double uy) const { return u.enabled ? finish(tone(c), ux, uy) : c; }
    // What float32 rounding is worth at this pixel: the largest output change
    // when one channel of the tone result moves by 2^-23, one ulp of 1.0 --
    // the absolute scale of float rounding in values that pass through O(1),
    // which a small result of a cancellation (the black point taken off a
    // value close to it) still carries. The luma curve's ratio multiplies it
    // (a curve that starts at y = 0.55 lifts a luma of 0.0033 by 167) and the
    // channel rows by their slopes (an entry can rise 0.2 in 1/255, 51), so
    // neither the Mac's float kernel nor this one can be closer to the double
    // result than about this.
    double sensitivity(const D3& c, double ux, double uy) const {
        if (!u.enabled) return 0;
        const D3 t = tone(c), r0 = finish(t, ux, uy);
        double worst = 0;
        for (int k = 0; k < 3; ++k)
            for (double s : {-1.0, 1.0}) {
                D3 p = t;
                p[k] += s * 1.1920928955078125e-7;
                const D3 r = finish(p, ux, uy);
                for (int j = 0; j < 3; ++j) worst = std::max(worst, std::abs(r[j] - r0[j]));
            }
        return worst;
    }
    // Steps 7 and 9 and the final saturate.
    D3 finish(D3 c, double ux, double uy) const {
        if (u.curvesActive) {
            for (auto& v : c) v = saturate(v);
            double ly = luma(c);
            double ly2 = lookup(1, ly);
            for (auto& v : c) v *= (ly > f(1e-4f)) ? (ly2 / ly) : 1.0;
            for (auto& v : c) v = saturate(v);
            c = {lookup(0, c[0]), lookup(0, c[1]), lookup(0, c[2])};
            c = {lookup(2, c[0]), lookup(3, c[1]), lookup(4, c[2])};
        }
        if (u.vignetteAmount != 0.0f) {
            double px = (ux - 0.5) * 2.0, py = (uy - 0.5) * 2.0;
            double d = std::sqrt(px * px + py * py);
            double e0 = u.vignetteMidpoint * f(1.2f), e1 = 1.5;
            double t = saturate((d - e0) / (e1 - e0));
            double fall = t * t * (3.0 - 2.0 * t);
            for (auto& v : c) v *= 1.0 + u.vignetteAmount * fall * f(0.9f);
        }
        for (auto& v : c) v = saturate(v);
        return c;
    }
};

Oracle oracle(const pd::Params& p, float midGrey) { return {macUniforms(p, midGrey), macTables(p.curves)}; }

// ---------------------------------------------------------------------------
// Synthetic frames: a grey ramp, the 9^3 colour cube, values a hair outside
// [0,1] (Windows frames are float; the max(c, 0) guards must hold), then
// random colours. Every pixel has its own uv, so the vignette is exercised
// across the frame.
// ---------------------------------------------------------------------------
constexpr int frameW = 128, frameH = 96;

std::vector<float> syntheticFrame(int w, int h, unsigned seed) {
    std::vector<float> rgba(size_t(w) * h * 4, 1.0f);
    Random random(seed);
    size_t k = 0;
    auto put = [&](double r, double g, double b) {
        if (k >= size_t(w) * h) return;
        rgba[4 * k] = float(r);
        rgba[4 * k + 1] = float(g);
        rgba[4 * k + 2] = float(b);
        ++k;
    };
    for (int i = 0; i <= 256; ++i) put(i / 256.0, i / 256.0, i / 256.0);
    for (int r = 0; r <= 8; ++r)
        for (int g = 0; g <= 8; ++g)
            for (int b = 0; b <= 8; ++b) put(r / 8.0, g / 8.0, b / 8.0);
    for (double v : {-0.05, -0.001, 1.001, 1.08}) {
        put(v, 0.5, 0.5);
        put(0.3, v, 0.7);
        put(v, v, v);
    }
    while (k < size_t(w) * h) put(random.uniform(), random.uniform(), random.uniform());
    return rgba;
}

pd::Curve curve(std::initializer_list<pd::CurvePoint> points) {
    pd::Curve c;
    c.points = points;
    return c;
}

pd::Curve randomCurve(Random& random, int n, bool monotone) {
    pd::Curve c;
    c.points.clear();
    std::vector<double> xs{0.0, 1.0};
    for (int i = 0; i < n - 2; ++i) xs.push_back(random.range(0.02, 0.98));
    std::sort(xs.begin(), xs.end());
    double y = random.range(0.0, 0.2);
    for (double x : xs) {
        if (monotone) y = std::min(1.0, y + random.range(0.0, 2.0 / n));
        else y = random.uniform();
        c.points.push_back({x, y});
    }
    return c;
}

pd::Params randomParams(Random& random, bool withCurves) {
    pd::Params p;
    p.temperature = random.range(-100, 100);
    p.tint = random.range(-100, 100);
    p.exposure = random.range(-3, 3);
    p.contrast = random.range(-50, 50);
    p.brightness = random.range(-50, 50);
    p.saturation = random.range(-100, 100);
    p.highlights = random.range(-100, 100);
    p.shadows = random.range(-100, 100);
    p.blackPoint = random.range(0, 50);
    p.whitePoint = random.range(0, 50);
    for (pd::ColorZone* z : {&p.colorBalance.master, &p.colorBalance.shadows, &p.colorBalance.midtones,
                             &p.colorBalance.highlights})
        *z = {random.range(0, 360), random.range(0, 1), random.range(-1, 1)};
    p.vignette = {random.range(-100, 100), random.range(0, 100)};
    if (withCurves)
        for (int ch = 0; ch < 5; ++ch)
            p.curves[pd::CurveChannel(ch)] = randomCurve(random, 2 + int(random.range(1, 9)), ch != 1);
    return p;
}

struct Case {
    std::string group, name;
    pd::Params params;
    float midGrey = pd::proPhotoMidGrey;
};

// One control at a time across its range, then everything at once.
std::vector<Case> cases() {
    std::vector<Case> out;
    auto add = [&](const std::string& group, const std::string& name, const std::function<void(pd::Params&)>& edit,
                   float midGrey = pd::proPhotoMidGrey) {
        pd::Params p;
        edit(p);
        out.push_back({group, name, p, midGrey});
    };
    using Member = double pd::Params::*;
    const std::pair<const char*, Member> scalars[] = {
        {"temperature", &pd::Params::temperature}, {"tint", &pd::Params::tint},
        {"exposure", &pd::Params::exposure}, {"contrast", &pd::Params::contrast},
        {"brightness", &pd::Params::brightness}, {"saturation", &pd::Params::saturation},
        {"highlights", &pd::Params::highlights}, {"shadows", &pd::Params::shadows},
        {"blackPoint", &pd::Params::blackPoint}, {"whitePoint", &pd::Params::whitePoint}};
    for (const auto& [name, member] : scalars) {
        const auto& field = *std::find_if(pd::fields().begin(), pd::fields().end(),
                                          [&](const pd::Field& f) { return std::strcmp(f.path, name) == 0; });
        for (double t : {0.0, 0.2, 0.62, 1.0}) {
            double v = field.low + (field.high - field.low) * t;
            if (v == 0) v = field.high * 0.1;
            add(name, fmt("%+g", v), [&, member = member](pd::Params& p) { p.*member = v; });
            add(name, fmt("%+g sRGB pivot", v), [&, member = member](pd::Params& p) { p.*member = v; },
                pd::srgbMidGrey);
        }
    }
    add("blackPoint", "black 50 + white 50 (span floor)", [](pd::Params& p) { p.blackPoint = 50; p.whitePoint = 50; });
    const std::pair<const char*, pd::ColorZone pd::ColorBalance::*> zones[] = {
        {"master", &pd::ColorBalance::master}, {"shadows", &pd::ColorBalance::shadows},
        {"midtones", &pd::ColorBalance::midtones}, {"highlights", &pd::ColorBalance::highlights}};
    const pd::ColorZone zoneValues[] = {{0, 1, 0}, {37, 0.6, -0.4}, {200, 0.3, 0.7}, {300, 1, -1}, {120, 0, 1}};
    for (const auto& [name, member] : zones)
        for (const auto& z : zoneValues)
            add(std::string("colorBalance.") + name, fmt("h%g s%g l%g", z.hue, z.saturation, z.luminance),
                [&, member = member](pd::Params& p) { p.colorBalance.*member = z; });
    for (double amount : {-100.0, -40.0, 60.0, 100.0})
        for (double midpoint : {0.0, 50.0, 100.0})
            add("vignette", fmt("amount %g midpoint %g", amount, midpoint),
                [=](pd::Params& p) { p.vignette = {amount, midpoint}; });
    add("curves", "rgb S", [](pd::Params& p) { p.curves.rgb = curve({{0, 0}, {0.25, 0.18}, {0.75, 0.84}, {1, 1}}); });
    add("curves", "luma lift", [](pd::Params& p) { p.curves.luma = curve({{0, 0}, {0.05, 0.3}, {1, 1}}); });
    add("curves", "luma crush", [](pd::Params& p) { p.curves.luma = curve({{0, 0.1}, {0.6, 0.2}, {1, 0.9}}); });
    add("curves", "red down", [](pd::Params& p) { p.curves.red = curve({{0, 0}, {0.5, 0.35}, {1, 1}}); });
    add("curves", "green steep", [](pd::Params& p) { p.curves.green = curve({{0, 0}, {0.1, 0.9}, {0.2, 0.95}, {1, 1}}); });
    add("curves", "blue inverted", [](pd::Params& p) { p.curves.blue = curve({{0, 1}, {1, 0}}); });
    add("curves", "identity points, curves on", [](pd::Params& p) { p.curves.red = curve({{0, 0}, {0.5, 0.5}, {1, 1}}); });
    add("curves", "all five", [](pd::Params& p) {
        p.curves.rgb = curve({{0, 0.04}, {0.5, 0.55}, {1, 0.97}});
        p.curves.luma = curve({{0, 0}, {0.3, 0.25}, {0.7, 0.8}, {1, 1}});
        p.curves.red = curve({{0, 0}, {0.4, 0.45}, {1, 1}});
        p.curves.green = curve({{0, 0.02}, {1, 1}});
        p.curves.blue = curve({{0, 0}, {0.6, 0.5}, {1, 0.95}});
    });
    Random random(2026);
    for (int i = 0; i < 12; ++i) {
        const pd::Params p = randomParams(random, true);
        out.push_back({"everything", fmt("random set %g", i), p, i % 2 ? pd::srgbMidGrey : pd::proPhotoMidGrey});
    }
    for (int i = 0; i < 4; ++i) {
        const pd::Params p = randomParams(random, false);
        out.push_back({"everything", fmt("random set, no curves %g", i), p, pd::proPhotoMidGrey});
    }
    return out;
}

// Max |a - b| over RGB, alpha ignored; `at` gets the worst sample's index.
double maxDifference(const std::vector<float>& a, const std::vector<double>& b, size_t* at = nullptr) {
    double worst = 0;
    for (size_t i = 0; i < a.size(); ++i)
        if (i % 4 != 3 && std::abs(double(a[i]) - b[i]) > worst) {
            worst = std::abs(double(a[i]) - b[i]);
            if (at) *at = i;
        }
    return worst;
}
double maxDifference(const std::vector<float>& a, const std::vector<float>& b) {
    double worst = 0;
    for (size_t i = 0; i < a.size(); ++i)
        if (i % 4 != 3) worst = std::max(worst, std::abs(double(a[i]) - double(b[i])));
    return worst;
}

struct Reference {
    std::vector<double> rgba;
    std::vector<double> sensitivity; // per pixel, Oracle::sensitivity
};

Reference oracleFrame(const std::vector<float>& rgba, int w, int h, const Oracle& o) {
    Reference out{std::vector<double>(rgba.size()), std::vector<double>(size_t(w) * h)};
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            const size_t i = (size_t(y) * w + x) * 4;
            const D3 in{rgba[i], rgba[i + 1], rgba[i + 2]};
            const D3 c = o.pixel(in, (x + 0.5) / w, (y + 0.5) / h);
            out.rgba[i] = c[0];
            out.rgba[i + 1] = c[1];
            out.rgba[i + 2] = c[2];
            out.rgba[i + 3] = rgba[i + 3];
            out.sensitivity[i / 4] = o.sensitivity(in, (x + 0.5) / w, (y + 0.5) / h);
        }
    return out;
}

// Each pixel is held to `bar` plus sixteen ulps' worth of its own
// conditioning (Oracle::sensitivity): flat wherever the grade is
// well-conditioned, wider only where the curves magnify float rounding.
// "Well-conditioned" is a sensitivity under 1e-6, an amplification of less
// than about 8 on the tone result; there the flat bar is checked alone.
struct Comparison {
    double worst = 0, worstWellConditioned = 0, worstSensitivity = 0;
    size_t at = 0, failedAt = 0;
    bool pass = true;
};
Comparison compare(const std::vector<float>& got, const Reference& ref, double bar) {
    Comparison c;
    for (size_t p = 0; p < ref.sensitivity.size(); ++p) {
        double e = 0;
        for (int k = 0; k < 3; ++k) e = std::max(e, std::abs(double(got[4 * p + k]) - ref.rgba[4 * p + k]));
        const double s = ref.sensitivity[p];
        if (e > c.worst) { c.worst = e; c.at = p; }
        if (s < 1e-6) c.worstWellConditioned = std::max(c.worstWellConditioned, e);
        c.worstSensitivity = std::max(c.worstSensitivity, s);
        if (c.pass && e > bar + 16 * s) { c.pass = false; c.failedAt = p; }
    }
    return c;
}
std::string describe(const std::vector<float>& input, const std::vector<float>& got, const Reference& ref, size_t p) {
    return fmt(" at pixel %g, input (%.9g, ", double(p), input[4 * p]) +
           fmt("%.9g, %.9g)", input[4 * p + 1], input[4 * p + 2]) +
           fmt(" got (%.9g, %.9g, %.9g)", got[4 * p], got[4 * p + 1], got[4 * p + 2]) +
           fmt(" want (%.9g, %.9g, %.9g)", ref.rgba[4 * p], ref.rgba[4 * p + 1], ref.rgba[4 * p + 2]) +
           fmt(" sensitivity %.3g", ref.sensitivity[p]);
}

std::vector<float> cpuFrame(std::vector<float> rgba, int w, int h, const pd::Grade& grade, int threads = 1) {
    grade.apply(rgba.data(), w, h, 4, 0, threads);
    return rgba;
}

// The bar against the oracle: one count of the Mac's own output, which is an
// rgba16Unorm texture (TextureStore.swift:409-413) -- flat wherever the grade
// is well-conditioned, plus the pixel's own conditioning where the curves
// magnify float rounding (compare(), Oracle::sensitivity). The CPU path is
// float32 throughout, as the kernel is; what separates it from a double
// transcription is float rounding, the closed-form exposure and powf. The
// measured worst cases are printed.
constexpr double oracleTolerance = 1.0 / 65535.0;

// ---------------------------------------------------------------------------
// --cpu
// ---------------------------------------------------------------------------

void testModel() {
    // Adjustments.swift:48-68 defaults; the ranges of RightSections.swift:39-82,
    // CameraSection.swift:82-85 and AgentSchema.swift:202-225.
    const pd::Params p;
    check(p.enabled && p.temperature == 0 && p.tint == 0 && p.exposure == 0 && p.contrast == 0 &&
              p.brightness == 0 && p.saturation == 0 && p.highlights == 0 && p.shadows == 0 &&
              p.blackPoint == 0 && p.whitePoint == 0 && p.vignette.amount == 0 && p.vignette.midpoint == 50,
          "defaults are the Mac's");
    check(p.curves.isIdentity() && p.colorBalance.isNeutral() && p.isNeutral(), "a fresh grade is neutral");
    struct Expect { const char* path; double low, high, initial, snap; };
    const Expect expected[] = {
        {"temperature", -100, 100, 0, 5}, {"tint", -100, 100, 0, 5}, {"exposure", -3, 3, 0, 0.25},
        {"contrast", -50, 50, 0, 5}, {"brightness", -50, 50, 0, 5}, {"saturation", -100, 100, 0, 5},
        {"highlights", -100, 100, 0, 5}, {"shadows", -100, 100, 0, 5}, {"blackPoint", 0, 50, 0, 1},
        {"whitePoint", 0, 50, 0, 1}, {"vignette.amount", -100, 100, 0, 5}, {"vignette.midpoint", 0, 100, 50, 0},
        {"colorBalance.midtones.hue", 0, 360, 0, 0}, {"colorBalance.shadows.saturation", 0, 1, 0, 0},
        {"colorBalance.highlights.luminance", -1, 1, 0, 0}};
    check(pd::fields().size() == 24, "24 scalar controls: 10 sliders, 2 vignette, 4 zones x 3");
    for (const auto& e : expected) {
        const auto it = std::find_if(pd::fields().begin(), pd::fields().end(),
                                     [&](const pd::Field& f) { return std::strcmp(f.path, e.path) == 0; });
        check(it != pd::fields().end(), std::string("field listed: ") + e.path);
        check(it->low == e.low && it->high == e.high && it->initial == e.initial && it->snap == e.snap,
              std::string("field range: ") + e.path);
    }
    // isNeutral is Swift's (== defaults); identity is "changes no pixel".
    pd::Params hueOnly;
    hueOnly.colorBalance.midtones.hue = 120;
    hueOnly.vignette.midpoint = 80;
    check(!hueOnly.isNeutral() && pd::Grade(hueOnly).isIdentity(), "a hue at zero saturation is no grade");
    Random random(5);
    pd::Params off = randomParams(random, true);
    off.enabled = false;
    check(!off.isNeutral() && pd::Grade(off).isIdentity(), "bypass is identity");
}

void testUniforms() {
    // The derivation in Float, against the Swift transcription, bit for bit.
    Random random(7);
    for (int i = 0; i < 200; ++i) {
        const pd::Params p = randomParams(random, i % 3 == 0);
        const float mg = i % 2 ? pd::srgbMidGrey : pd::proPhotoMidGrey;
        const auto u = pd::uniforms(p, mg);
        const auto m = macUniforms(p, mg);
        bool same = u.exposureGain == m.exposureGain && u.contrast == m.contrast && u.brightness == m.brightness &&
                    u.saturation == m.saturation && u.highlights == m.highlights && u.shadows == m.shadows &&
                    u.blackPoint == m.blackPoint && u.whitePoint == m.whitePoint &&
                    u.vignetteAmount == m.vignetteAmount && u.vignetteMidpoint == m.vignetteMidpoint &&
                    u.midGrey == m.midGrey && u.curvesActive == m.curvesActive && u.enabled == m.enabled;
        for (int k = 0; k < 3; ++k)
            same = same && u.wbGain[k] == m.wb[k] && u.cbMaster[k] == m.cbMaster[k] &&
                   u.cbShadows[k] == m.cbShadows[k] && u.cbMidtones[k] == m.cbMidtones[k] &&
                   u.cbHighlights[k] == m.cbHighlights[k];
        for (int k = 0; k < 4; ++k) same = same && u.cbLum[k] == m.cbLum[k];
        check(same, "uniforms match Adjustments.swift's Float arithmetic");
    }
    pd::Params p;
    p.temperature = 100;
    p.tint = -100;
    p.exposure = 1;
    const auto u = pd::uniforms(p);
    // Float arithmetic, as Swift: 1 + 0.18 * 1 is not the literal 1.18f.
    check(u.wbGain[0] == 1.0f + 0.18f && u.wbGain[1] == 1.0f + 0.12f && u.wbGain[2] == 1.0f - 0.18f &&
              std::abs(u.wbGain[0] - 1.18) < 1e-6 && std::abs(u.wbGain[1] - 1.12) < 1e-6 &&
              std::abs(u.wbGain[2] - 0.82) < 1e-6,
          "temperature/tint gains");
    check(u.exposureGain == 2.0f && std::abs(u.exposureScale - 1.3703509f) < 1e-6f, "exposure gain and scale");
    check(pd::proPhotoMidGrey == 0.3857f && pd::srgbMidGrey == 0.4614f, "the Mac's two pivots");
    check(std::abs(std::pow(0.18, 1 / 1.8) - pd::proPhotoMidGrey) < 5e-5, "ROMM mid-grey");
    // Zones: 0 deg is red, 120 green; s * 0.25 (Adjustments.swift:25-31).
    const auto red = pd::ColorZone{0, 1, 0}.rgbOffset(), green = pd::ColorZone{120, 1, 0}.rgbOffset();
    check(red[0] == 0.25f && std::abs(red[1] + 0.125f) < 1e-7f && std::abs(red[2] + 0.125f) < 1e-7f, "hue 0 is red");
    check(std::abs(green[0] + 0.125f) < 1e-7f && std::abs(green[1] - 0.25f) < 1e-7f, "hue 120 is green");
    // midGreyFor follows the transfer function and refuses linear data.
    check(pd::midGreyFor(QColorSpace(QColorSpace::SRgb)) == pd::srgbMidGrey, "sRGB pivot");
    check(pd::midGreyFor(QColorSpace(QColorSpace::DisplayP3)) == pd::srgbMidGrey, "Display P3 has sRGB's curve");
    check(pd::midGreyFor(QColorSpace(QColorSpace::ProPhotoRgb)) == pd::proPhotoMidGrey, "ProPhoto pivot");
    check(pd::midGreyFor(QColorSpace(QColorSpace::Primaries::ProPhotoRgb, 1.8f)) == pd::proPhotoMidGrey,
          "gamma 1.8 ProPhoto pivot");
    check(!pd::midGreyFor(QColorSpace(QColorSpace::SRgbLinear)).has_value(), "linear data is refused");
    check(!pd::midGreyFor(QColorSpace()).has_value(), "no colour space is refused");
}

void testCurve() {
    // Hand-derived from CurveMath.swift: (0,0),(0.5,0.75),(1,1) has secants
    // 1.5 and 0.5, tangents 1.5, 1.0, 0.5, no limiting; at t = 1/2 the
    // Hermite basis is (1/2, 1/8, 1/2, -1/8).
    const auto simple = curve({{0, 0}, {0.5, 0.75}, {1, 1}});
    check(simple.evaluate(0.25) == 0.40625 && simple.evaluate(0.75) == 0.90625, "hand-derived values");
    check(simple.evaluate(0.5) == 0.75 && simple.evaluate(0) == 0 && simple.evaluate(1) == 1, "control points");
    check(pd::Curve{}.isIdentity() && pd::Curve{}.evaluate(0.3) == 0.3, "identity curve");
    // The limiter is live: unlimited tangents (4.75 at x = 0.1) overshoot
    // 0.95 inside [0.1, 0.2]; Fritsch-Carlson keeps the curve monotone.
    const auto steep = curve({{0, 0}, {0.1, 0.9}, {0.2, 0.95}, {1, 1}});
    double previous = -1;
    for (int i = 0; i <= 4000; ++i) {
        const double y = steep.evaluate(i / 4000.0);
        check(y >= previous - 1e-15, "monotone data gives a monotone curve");
        previous = y;
        if (i >= 400 && i <= 800) check(y >= 0.9 - 1e-12 && y <= 0.95 + 1e-12, "no overshoot between 0.1 and 0.2");
    }
    // Against the transcription of CurveMath.swift, at its control points
    // and between, on curves of every kind the editor can make: monotone
    // and not, 2 to 64 points (past the store's cap: the spline has none), a
    // repeated x, ends off 0 and 1.
    Random random(11);
    std::vector<pd::Curve> curves{simple, steep, curve({{0, 1}, {1, 0}}),
                                  curve({{0, 0.2}, {0.3, 0.3}, {0.3, 0.6}, {1, 0.8}}),
                                  curve({{0, 0}, {0.5, 0.5}, {0.5, 0.5}, {1, 1}})};
    for (int i = 0; i < 60; ++i) curves.push_back(randomCurve(random, 2 + i % 63, i % 2 == 0));
    size_t compared = 0;
    for (const auto& c : curves) {
        std::vector<double> xs;
        for (int i = 0; i <= 1024; ++i) xs.push_back(i / 1024.0);
        for (const auto& p : c.points) {
            xs.push_back(p.x);
            xs.push_back(std::nextafter(p.x, 0.0));
            xs.push_back(std::nextafter(p.x, 1.0));
        }
        for (double x : xs) {
            check(c.evaluate(x) == macEvaluate(c.points, x), fmt("curve matches CurveMath.swift at x = %.17g", x));
            ++compared;
        }
        for (size_t i = 0; i < c.points.size(); ++i) {
            const bool repeated = (i > 0 && c.points[i - 1].x == c.points[i].x) ||
                                  (i + 1 < c.points.size() && c.points[i + 1].x == c.points[i].x);
            if (!repeated) check(c.evaluate(c.points[i].x) == c.points[i].y, "passes through its points");
        }
    }
    std::printf("  curve: %zu evaluations identical to the CurveMath.swift transcription\n", compared);
    // The table: Float(evaluate(i / 255)), rows rgb, luma, red, green, blue.
    pd::CurveSet set;
    set.red = steep;
    set.luma = simple;
    const auto tables = pd::curveTables(set);
    const auto mac = macTables(set);
    check(std::equal(tables.begin(), tables.end(), mac.begin()), "tables are the Mac's, row for row");
    check(tables[2 * 256 + 26] == float(steep.evaluate(26.0 / 255.0)) && tables[0 * 256 + 64] == float(64.0 / 255.0),
          "row order and entry spacing");
    // The lookup is the Mac's texel-centre sampler, not entry x * 255: an
    // identity row reads (256 x - 0.5) / 255 -- up to half an 8-bit count off.
    const float* identityRow = tables.data();
    check(std::abs(pd::curveLookup(identityRow, 0.25f) - (64.0 - 0.5) / 255.0) < 1e-7,
          "identity row at 0.25 reads 0.24902");
    check(pd::curveLookup(identityRow, 0.0f) == 0.0f && pd::curveLookup(identityRow, 1.0f) == 1.0f, "row ends");
    check(std::abs(pd::curveLookup(identityRow, 0.5f) - 0.5f) < 1e-7f, "the stretch is about 0.5");
    double worst = 0;
    for (int i = 0; i <= 4096; ++i) worst = std::max(worst, std::abs(pd::curveLookup(identityRow, i / 4096.0f) - i / 4096.0));
    check(worst > 0.0019 && worst < 0.5 / 255 + 1e-6, "identity-row deviation peaks at 0.5/255");
    std::printf("  curve: identity row through the Mac's sampler deviates up to %.6f (0.5/255 = %.6f)\n", worst,
                0.5 / 255);
    // The editor's operations (CurveMath.swift:35-103).
    pd::Curve c;
    check(c.insert({0.5, 0.7}) == 1 && c.points.size() == 3, "insert keeps the list sorted");
    check(c.insert({-1, 2}) == 1 && c.points[1].x == 0 && c.points[1].y == 1, "insert clamps; x = 0 goes after the end");
    c.remove(1);
    c.move(0, {0.4, 0.2});
    check(c.points[0].x == 0 && c.points[0].y == 0.2, "the first point keeps x = 0");
    c.move(1, {0.995, 0.5});
    check(c.points[1].x == 1 - 0.01, "an interior point stays 0.01 from its neighbour");
    c.move(2, {0.2, 0.9});
    check(c.points[2].x == 1 && c.points[2].y == 0.9, "the last point keeps x = 1");
    check(!c.isDeletable(0) && !c.isDeletable(2) && c.isDeletable(1), "only interior points are deletable");
    c.remove(0);
    check(c.points.size() == 3, "an end is not removed");
    check(c.indexNear({0.99, 0.51}, 0.05) == 1 && !c.indexNear({0.5, 0.0}, 0.05), "hit test");
    check(pd::Curve::hitTolerance(200, 100) == 0.1 && pd::Curve::hitTolerance(0, 100) == 0, "ten pixels of travel");
    pd::Curve full;
    for (int i = 0; i < 70; ++i) full.insert({i / 80.0 + 0.001, 0.5});
    check(int(full.points.size()) == pd::Curve::maxPoints && full.insert({0.5, 0.5}) == -1,
          "insert stops at the store's 32 points");
}

void testIdentity() {
    // Bit-exact: no grade, bypass, and edits that land on no grade.
    Random random(3);
    const int w = 61, h = 37, stride = w * 4 + 5;
    std::vector<float> frame(size_t(stride) * h);
    for (auto& v : frame) v = float(random.range(-0.5, 1.5));
    frame[0] = std::numeric_limits<float>::quiet_NaN();
    frame[1] = -0.0f;
    frame[2] = std::numeric_limits<float>::denorm_min();
    frame[4] = std::numeric_limits<float>::infinity();
    std::vector<pd::Params> identities(3);
    identities[1] = randomParams(random, true);
    identities[1].enabled = false;
    identities[2].curves.red = curve({{0, 0}, {1, 1}});
    identities[2].colorBalance.shadows.hue = 250;
    identities[2].vignette.midpoint = 10;
    identities[2].exposure = 1e-12; // Float(2^1e-12) == 1
    for (const auto& p : identities) {
        const pd::Grade grade(p);
        check(grade.isIdentity(), "identity grade");
        for (int channels : {3, 4}) {
            auto copy = frame;
            grade.apply(copy.data(), w, h, channels, stride, 0);
            check(std::memcmp(copy.data(), frame.data(), frame.size() * sizeof(float)) == 0,
                  "identity is bit-exact on float pixels");
        }
        QImage image(w, h, QImage::Format_RGBA64);
        for (int y = 0; y < h; ++y)
            for (int x = 0; x < w; ++x)
                image.setPixelColor(x, y, QColor::fromRgba64(quint16(random.gen()), quint16(random.gen()),
                                                             quint16(random.gen()), quint16(random.gen())));
        QImage copy = image.copy();
        grade.apply(copy);
        check(copy == image, "identity is bit-exact on RGBA64");
        const auto block = pd::std140(grade);
        check(block[36] == 0.0f, "an identity grade is inactive on the GPU too");
    }
}

// The worst of each control group, for the printed table.
struct GroupSummary {
    std::string group;
    double worst = 0, worstWellConditioned = 0, worstSensitivity = 0;
};
void note(std::vector<GroupSummary>& table, const std::string& group, const Comparison& c) {
    auto it = std::find_if(table.begin(), table.end(), [&](const GroupSummary& g) { return g.group == group; });
    if (it == table.end()) it = table.insert(table.end(), {group});
    it->worst = std::max(it->worst, c.worst);
    it->worstWellConditioned = std::max(it->worstWellConditioned, c.worstWellConditioned);
    it->worstSensitivity = std::max(it->worstSensitivity, c.worstSensitivity);
}
void print(const char* title, const std::vector<GroupSummary>& table) {
    std::printf("  %s\n    %-24s %12s %16s %14s\n", title, "control", "worst", "well-conditioned", "sensitivity");
    for (const auto& g : table)
        std::printf("    %-24s %12.3g %16.3g %14.3g\n", g.group.c_str(), g.worst, g.worstWellConditioned,
                    g.worstSensitivity);
}

void testOracle() {
    const auto frame = syntheticFrame(frameW, frameH, 1);
    std::vector<GroupSummary> table;
    for (const auto& c : cases()) {
        const pd::Grade grade(c.params, c.midGrey);
        check(!grade.isIdentity(), "case is a grade: " + c.group + " " + c.name);
        const auto cpu = cpuFrame(frame, frameW, frameH, grade);
        const auto mac = oracleFrame(frame, frameW, frameH, oracle(c.params, c.midGrey));
        const auto result = compare(cpu, mac, oracleTolerance);
        note(table, c.group, result);
        check(result.pass, "CPU vs Shaders.metal transcription beyond 1/65535 + 16 ulps' conditioning: " + c.group +
                               " " + c.name + describe(frame, cpu, mac, result.failedAt));
        // Where the grade is well-conditioned the flat bar holds.
        check(result.worstWellConditioned <= oracleTolerance, "flat 1/65535 bar: " + c.group + " " + c.name);
        // And something visibly happened.
        if (c.name.find("identity points") == std::string::npos)
            check(maxDifference(cpu, std::vector<double>(frame.begin(), frame.end())) > 1e-3,
                  "the grade moves pixels: " + c.group + " " + c.name);
    }
    print("CPU vs the double transcription of Shaders.metal (|error|; sensitivity = one float ulp of the tone "
          "result, through the grade):",
          table);
}

void testDeterminism() {
    const int w = 1023, h = 517;
    Random random(9);
    std::vector<float> frame(size_t(w) * h * 4);
    for (auto& v : frame) v = float(random.uniform());
    const pd::Grade grade(randomParams(random, true));
    const auto reference = cpuFrame(frame, w, h, grade, 1);
    for (int threads : {2, 3, 5, 8, 16, 0}) {
        const auto out = cpuFrame(frame, w, h, grade, threads);
        check(std::memcmp(out.data(), reference.data(), out.size() * sizeof(float)) == 0,
              fmt("bit-identical with %g threads", threads));
    }
    QImage image(w, h, QImage::Format_RGBA64);
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x)
            image.setPixelColor(x, y, QColor::fromRgba64(quint16(random.gen()), quint16(random.gen()),
                                                         quint16(random.gen()), 65535));
    QImage one = image.copy(), many = image.copy();
    grade.apply(one, 1);
    grade.apply(many, 0);
    check(one == many, "RGBA64 bit-identical across thread counts");
    // A tile graded with its own SourceRect is the same pixels as the frame.
    auto tile = std::vector<float>(frame.begin() + size_t(100) * w * 4, frame.begin() + size_t(164) * w * 4);
    grade.apply(tile.data(), w, 64, 4, 0, 0, {0, 100.0 / h, 1, 64.0 / h});
    double e = 0;
    for (size_t i = 0; i < tile.size(); ++i) e = std::max(e, double(std::abs(tile[i] - reference[size_t(100) * w * 4 + i])));
    check(e < 1e-6, "a tile with its SourceRect matches the whole frame");
}

void testImageFormats() {
    // Plumbing, exactly: each format is its samples dequantised, the float
    // path, and rounded back -- byte order and rounding, nothing else.
    const auto frame = syntheticFrame(frameW, frameH, 4);
    Random random(21);
    const pd::Grade grade(randomParams(random, true));
    auto inRange = [](float v) { return std::clamp(v, 0.0f, 1.0f); };
    QImage f32(frameW, frameH, QImage::Format_RGBA32FPx4);
    QImage u16(frameW, frameH, QImage::Format_RGBX64);
    QImage u8(frameW, frameH, QImage::Format_RGB32);
    std::vector<float> from16(frame.size(), 1.0f), from8(frame.size(), 1.0f);
    for (int y = 0; y < frameH; ++y)
        for (int x = 0; x < frameW; ++x) {
            const size_t i = (size_t(y) * frameW + x) * 4;
            const float* c = &frame[i];
            std::copy(c, c + 4, reinterpret_cast<float*>(f32.scanLine(y)) + 4 * x);
            auto* s = reinterpret_cast<quint16*>(u16.scanLine(y)) + 4 * x;
            for (int k = 0; k < 3; ++k) {
                s[k] = quint16(inRange(c[k]) * 65535.0f + 0.5f);
                from16[i + k] = s[k] / 65535.0f;
            }
            s[3] = 65535;
            const int b[3] = {int(inRange(c[0]) * 255 + 0.5f), int(inRange(c[1]) * 255 + 0.5f),
                              int(inRange(c[2]) * 255 + 0.5f)};
            reinterpret_cast<QRgb*>(u8.scanLine(y))[x] = qRgb(b[0], b[1], b[2]);
            for (int k = 0; k < 3; ++k) from8[i + k] = b[k] / 255.0f;
        }
    const auto expected = cpuFrame(frame, frameW, frameH, grade);
    const auto expected16 = cpuFrame(from16, frameW, frameH, grade);
    const auto expected8 = cpuFrame(from8, frameW, frameH, grade);
    grade.apply(f32);
    grade.apply(u16);
    grade.apply(u8);
    bool same32 = true, same16 = true, same8 = true;
    for (int y = 0; y < frameH; ++y)
        for (int x = 0; x < frameW; ++x) {
            const size_t i = (size_t(y) * frameW + x) * 4;
            const QRgb q = reinterpret_cast<const QRgb*>(u8.constScanLine(y))[x];
            const int got8[3] = {qRed(q), qGreen(q), qBlue(q)};
            for (int k = 0; k < 3; ++k) {
                same32 = same32 && reinterpret_cast<const float*>(f32.constScanLine(y))[4 * x + k] == expected[i + k];
                same16 = same16 && reinterpret_cast<const quint16*>(u16.constScanLine(y))[4 * x + k] ==
                                       quint16(expected16[i + k] * 65535.0f + 0.5f);
                same8 = same8 && got8[k] == int(expected8[i + k] * 255.0f + 0.5f);
            }
            same16 = same16 && reinterpret_cast<const quint16*>(u16.constScanLine(y))[4 * x + 3] == 65535;
            same8 = same8 && qAlpha(q) == 255;
        }
    check(same32, "RGBA32FPx4 is the float path");
    check(same16, "RGBX64 is the float path on its samples, rounded to 16 bits");
    check(same8, "RGB32 is the float path on its samples, rounded to 8 bits; alpha untouched");
    QImage indexed(4, 4, QImage::Format_Indexed8), premultiplied(4, 4, QImage::Format_RGBA64_Premultiplied);
    rejects([&] { grade.apply(indexed); }, "an indexed image");
    rejects([&] { grade.apply(premultiplied); }, "a premultiplied image");
    rejects([&] { std::vector<float> v(8); grade.apply(v.data(), 2, 1, 2); }, "two channels");
}

void testJson() {
    // Every key, the Mac's names and nesting.
    const auto json = pd::toJson(pd::Params{});
    for (const char* key : {"enabled", "temperature", "tint", "exposure", "contrast", "brightness", "saturation",
                            "highlights", "shadows", "blackPoint", "whitePoint", "curves", "colorBalance", "vignette"})
        check(json.contains(QLatin1String(key)), std::string("toJson writes ") + key);
    check(json.value("curves").toObject().value("luma").toObject().value("points").toArray() ==
              QJsonArray{QJsonArray{0.0, 0.0}, QJsonArray{1.0, 1.0}},
          "curve points as [x, y] pairs");
    // Round trip, through bytes, exactly.
    Random random(17);
    for (int i = 0; i < 50; ++i) {
        pd::Params p = randomParams(random, true);
        p.enabled = i % 4 != 0;
        if (i == 3) p.curves.rgb = randomCurve(random, pd::Curve::maxPoints, false);
        const auto bytes = QJsonDocument(pd::toJson(p)).toJson(QJsonDocument::Indented);
        QStringList unknown;
        const auto back = pd::fromJson(QJsonDocument::fromJson(bytes).object(), &unknown);
        check(back == p && unknown.isEmpty(), "JSON round trip is exact");
    }
    check(pd::fromJson(QJsonObject{}) == pd::Params{}, "an absent key is its default");
    // A Mac sidecar's `adjustments` object, as Swift's JSONEncoder writes it
    // (Adjustments.swift Codable, CGPoint as [x, y]), reads verbatim.
    const char* mac = R"({"whitePoint":3,"vignette":{"midpoint":50,"amount":-25},"tint":-4,"temperature":12,
        "shadows":15,"saturation":-10,"highlights":-20,"exposure":0.5,"enabled":true,"curves":{
        "red":{"points":[[0,0],[1,1]]},"rgb":{"points":[[0,0],[0.25,0.2],[0.75,0.8],[1,1]]},
        "luma":{"points":[[0,0],[1,1]]},"green":{"points":[[0,0],[1,1]]},"blue":{"points":[[0,0.05],[1,1]]}},
        "contrast":10,"colorBalance":{"master":{"hue":30,"saturation":0.2,"luminance":0},
        "shadows":{"hue":200,"saturation":0.5,"luminance":-0.1},"midtones":{"hue":0,"saturation":0,"luminance":0},
        "highlights":{"hue":60,"saturation":0.3,"luminance":0.05}},"brightness":5,"blackPoint":2})";
    const auto fromMac = pd::fromJson(QJsonDocument::fromJson(mac).object());
    check(fromMac.exposure == 0.5 && fromMac.contrast == 10 && fromMac.whitePoint == 3 && fromMac.vignette.amount == -25 &&
              fromMac.curves.rgb.points.size() == 4 && fromMac.curves.rgb.points[1] == pd::CurvePoint{0.25, 0.2} &&
              fromMac.curves.blue.points[0].y == 0.05 && fromMac.colorBalance.shadows.hue == 200 &&
              fromMac.colorBalance.highlights.luminance == 0.05,
          "a Mac sidecar's adjustments read verbatim");
    // A newer build's fields are reported, at every level, and kept by the
    // store's overlay; with no list they are an error.
    QJsonObject newer = pd::toJson(pd::Params{});
    newer.insert("grain", 3);
    auto curves = newer.value("curves").toObject();
    auto rgb = curves.value("rgb").toObject();
    rgb.insert("tension", 0.5);
    curves.insert("rgb", rgb);
    curves.insert("hue", QJsonObject{});
    newer.insert("curves", curves);
    auto vignette = newer.value("vignette").toObject();
    vignette.insert("roundness", 1);
    newer.insert("vignette", vignette);
    QStringList unknown;
    check(pd::fromJson(newer, &unknown) == pd::Params{}, "unknown fields are ignored");
    unknown.sort();
    check(unknown == QStringList{"state.postDev.curves.hue", "state.postDev.curves.rgb.tension",
                                 "state.postDev.grain", "state.postDev.vignette.roundness"},
          "unknown fields are reported with their paths");
    rejects([&] { pd::fromJson(newer); }, "unknown fields without a list");
    // Strict where present: types, ranges, the curve invariant.
    auto with = [](const char* key, const QJsonValue& value) {
        QJsonObject o;
        o.insert(QLatin1String(key), value);
        return o;
    };
    rejects([&] { pd::fromJson(with("exposure", 3.5)); }, "exposure 3.5");
    rejects([&] { pd::fromJson(with("exposure", "1")); }, "exposure as text");
    rejects([&] { pd::fromJson(with("enabled", 1)); }, "enabled as a number");
    rejects([&] { pd::fromJson(with("blackPoint", -1)); }, "black point -1");
    rejects([&] { pd::fromJson(with("contrast", 50.5)); }, "contrast 50.5");
    rejects([&] { pd::fromJson(with("vignette", QJsonObject{{"midpoint", 101}})); }, "midpoint 101");
    rejects([&] { pd::fromJson(with("vignette", 3)); }, "vignette not an object");
    rejects([&] { pd::fromJson(with("colorBalance", QJsonObject{{"master", QJsonObject{{"hue", 361}}}})); }, "hue 361");
    rejects([&] { pd::fromJson(with("colorBalance", QJsonObject{{"shadows", QJsonObject{{"saturation", 1.2}}}})); },
            "saturation 1.2");
    auto points = [&](const QJsonArray& list) {
        return with("curves", QJsonObject{{"luma", QJsonObject{{"points", list}}}});
    };
    rejects([&] { pd::fromJson(points(QJsonArray{QJsonArray{0, 0}})); }, "one point");
    rejects([&] { pd::fromJson(points(QJsonArray{QJsonArray{0, 0}, QJsonArray{0.7, 0.5}, QJsonArray{0.6, 0.5},
                                                  QJsonArray{1, 1}})); }, "unsorted points");
    rejects([&] { pd::fromJson(points(QJsonArray{QJsonArray{0.1, 0}, QJsonArray{1, 1}})); }, "first x not 0");
    rejects([&] { pd::fromJson(points(QJsonArray{QJsonArray{0, 0}, QJsonArray{0.9, 1}})); }, "last x not 1");
    rejects([&] { pd::fromJson(points(QJsonArray{QJsonArray{0, 0}, QJsonArray{1, 1.2}})); }, "y outside [0,1]");
    rejects([&] { pd::fromJson(points(QJsonArray{QJsonObject{{"x", 0}, {"y", 0}}, QJsonArray{1, 1}})); }, "{x, y}");
    rejects([&] { pd::fromJson(with("curves", QJsonObject{{"luma", QJsonObject{}}})); }, "a curve without points");
    QJsonArray tooMany;
    for (int i = 0; i <= pd::Curve::maxPoints; ++i) tooMany.append(QJsonArray{double(i) / pd::Curve::maxPoints, 0.5});
    rejects([&] { pd::fromJson(points(tooMany)); }, "65 points");
    const auto repeated = pd::fromJson(points(QJsonArray{QJsonArray{0, 0}, QJsonArray{0.4, 0.3}, QJsonArray{0.4, 0.6},
                                                         QJsonArray{1, 1}}));
    check(repeated.curves.luma.points.size() == 4, "a repeated x (the editor's insert) is accepted");
    // Five curves of 32 points, every coordinate 17 digits, at the depth the
    // store writes them (document -> state -> postDev) and indented as it
    // does (EditStore.cpp:439): what is left of its 64 KiB is the record's.
    pd::Params big;
    for (int ch = 0; ch < 5; ++ch) big.curves[pd::CurveChannel(ch)] = randomCurve(random, pd::Curve::maxPoints, false);
    const QJsonObject record{{"state", QJsonObject{{"postDev", pd::toJson(big)}}}};
    const auto size = QJsonDocument(record).toJson(QJsonDocument::Indented).size();
    std::printf("  json: worst-case state.postDev in an indented record: %lld bytes\n", (long long)size);
    check(size < 28 * 1024, fmt("worst-case postDev leaves 36 KiB of the store's 64: %g bytes", double(size)));
}

void testWheel() {
    // ColorWheel.swift:219-234 and 497-553.
    const double d = 150;
    const auto centre = pd::wheel::zoneAt(75, 75, d);
    check(centre.saturation == 0, "the centre is no colour");
    const auto right = pd::wheel::zoneAt(75 + 70, 75, d, {0, 0, 0.4});
    check(right.hue == 0 && right.saturation == 1 && right.luminance == 0.4, "right is red at full radius");
    const auto up = pd::wheel::zoneAt(75, 75 - 35, d);
    check(std::abs(up.hue - 90) < 1e-12 && std::abs(up.saturation - 0.5) < 1e-12, "up is 90 deg");
    const auto down = pd::wheel::zoneAt(75, 75 + 200, d);
    check(std::abs(down.hue - 270) < 1e-12 && down.saturation == 1, "below clamps to the rim at 270 deg");
    for (const pd::ColorZone z : {pd::ColorZone{33, 0.7, 0}, pd::ColorZone{250, 0.2, 0}, pd::ColorZone{359, 1, 0}}) {
        const auto [x, y] = pd::wheel::pointOf(z, d);
        const auto back = pd::wheel::zoneAt(x, y, d);
        check(std::abs(back.hue - z.hue) < 1e-9 && std::abs(back.saturation - z.saturation) < 1e-12,
              "pointOf and zoneAt invert each other");
    }
    using pd::wheel::Side;
    check(pd::wheel::arcTheta(0, Side::left) == 245 && pd::wheel::arcTheta(1, Side::left) == 115, "left arc ends");
    check(pd::wheel::arcTheta(0, Side::right) == -65 && pd::wheel::arcTheta(1, Side::right) == 65, "right arc ends");
    // The seam (ColorWheel.swift:524-533): the bottom of the left arc arrives
    // as -115 deg and must read as the minimum, not slam to the maximum.
    check(pd::wheel::arcValue(-115, Side::left, 0, 1) == 0, "the left arc's bottom is its minimum");
    check(pd::wheel::arcValue(115, Side::left, 0, 1) == 1 && pd::wheel::arcValue(0, Side::right, -1, 1) == 0,
          "tops and middles");
    check(std::abs(pd::wheel::arcAngle(0, 10, 10, 10) - 180) < 1e-12 && pd::wheel::arcAngle(10, 0, 10, 10) == 90,
          "screen angles, y down");
    check(pd::wheel::arcFraction(0.5, -1, 1) == 0.75 && pd::wheel::arcFraction(5, 0, 1) == 1, "fractions");
}

void testStd140() {
    // The C++ side writes each float where PostDev.hpp says it is.
    pd::Params p;
    p.temperature = 50;
    p.exposure = -1;
    p.contrast = 20;
    p.brightness = -10;
    p.saturation = 30;
    p.highlights = 40;
    p.shadows = -50;
    p.blackPoint = 4;
    p.whitePoint = 6;
    p.colorBalance.highlights = {90, 0.5, 0.4};
    p.vignette = {-30, 70};
    p.curves.blue = curve({{0, 0}, {1, 0.9}});
    const pd::Grade g(p, pd::srgbMidGrey);
    const auto b = pd::std140(g);
    const auto& u = g.uniforms();
    check(b[0] == u.wbGain[0] && b[2] == u.wbGain[2] && b[3] == u.exposureScale && b[4] == u.contrast &&
              b[5] == u.brightness && b[6] == u.saturation && b[7] == u.highlights && b[8] == u.shadows &&
              b[9] == u.blackPoint && b[10] == u.whitePoint && b[11] == pd::srgbMidGrey && b[24] == u.cbHighlights[0] &&
              b[31] == u.cbLum[3] && b[32] == u.vignetteAmount && b[33] == u.vignetteMidpoint && b[36] == 1 &&
              b[37] == 1 && b[38] == 1,
          "std140() fills the block in the documented order");
}

void cpuTests() {
    testModel();
    testUniforms();
    testCurve();
    testIdentity();
    testOracle();
    testDeterminism();
    testImageFormats();
    testJson();
    testWheel();
    testStd140();
}

// ---------------------------------------------------------------------------
// --bench
// ---------------------------------------------------------------------------

void benchmark(int w, int h) {
    std::printf("  bench: %d x %d (%.1f MP), %u hardware threads\n", w, h, w * double(h) / 1e6,
                std::thread::hardware_concurrency());
    std::vector<float> frame(size_t(w) * h * 4);
    Random random(1);
    for (size_t i = 0; i < frame.size(); ++i) frame[i] = float((i * 2654435761u) % 65536) / 65535.0f;
    pd::Params all = randomParams(random, true); // every control on, brightness's pow included
    pd::Params tone;                              // the cheap common case: exposure + contrast
    tone.exposure = 0.5;
    tone.contrast = 10;
    auto time = [&](const char* label, const std::function<void()>& run) {
        double best = 1e30;
        for (int i = 0; i < 3; ++i) {
            const auto start = std::chrono::steady_clock::now();
            run();
            best = std::min(best, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count());
        }
        std::printf("    %-46s %8.1f ms (best of 3)\n", label, best);
    };
    const pd::Grade gAll(all), gTone(tone), gNone{pd::Params{}};
    time("identity, float RGBA", [&] { gNone.apply(frame.data(), w, h, 4); });
    time("exposure + contrast, float RGBA, all threads", [&] { gTone.apply(frame.data(), w, h, 4); });
    time("every control + curves, float RGBA, all threads", [&] { gAll.apply(frame.data(), w, h, 4); });
    QImage image(w, h, QImage::Format_RGBX64);
    image.fill(QColor::fromRgba64(30000, 20000, 40000));
    time("every control + curves, RGBX64, all threads", [&] { gAll.apply(image); });
    const int rows = std::max(1, h / 8);
    double single = 0;
    {
        const auto start = std::chrono::steady_clock::now();
        gAll.apply(frame.data(), w, rows, 4, 0, 1);
        single = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count() * h / rows;
    }
    std::printf("    %-46s %8.1f ms (1/8 of the rows, scaled)\n", "every control + curves, float RGBA, 1 thread", single);
}

} // namespace

int main(int argc, char** argv) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
    QGuiApplication application(argc, argv);
    const auto args = application.arguments();
    const int benchAt = int(args.indexOf("--bench"));
    const bool cpu = args.contains("--cpu") || benchAt < 0;
    try {
        if (cpu) cpuTests();
        if (benchAt >= 0) {
            const int w = args.value(benchAt + 1).toInt(), h = args.value(benchAt + 2).toInt();
            benchmark(w > 0 ? w : 7008, h > 0 ? h : 4672);
        }
        std::printf("spk_qt_postdev: %d checks passed\n", checks);
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "spk_qt_postdev FAILED after %d checks: %s\n", checks, error.what());
        return 1;
    }
}
