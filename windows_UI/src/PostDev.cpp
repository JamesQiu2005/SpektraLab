#include "PostDev.hpp"
#include <QColorSpace>
#include <QImage>
#include <QJsonArray>
#include <QJsonValue>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <numbers>
#include <stdexcept>
#include <thread>

namespace spk::desktop::postdev {
namespace {

// Metal's saturate/max return the non-NaN operand, as D3D's min/max do; a
// NaN pixel becomes 0 rather than an index into the curve table.
inline float saturate(float v) { return v > 0.0f ? (v < 1.0f ? v : 1.0f) : 0.0f; }
inline float positive(float v) { return v > 0.0f ? v : 0.0f; }

// Shaders.metal:119, Rec. 709 weights on the encoded values.
inline float luma(const std::array<float, 3>& c) { return 0.2126f * c[0] + 0.7152f * c[1] + 0.0722f * c[2]; }

// Shaders.metal:136-143: mid-grey at 0.5, piecewise linear, identity at
// midGrey == 0.5; a degenerate pivot falls back to 0.5.
inline float tonePosition(float l, float midGrey) {
    float m = saturate(midGrey);
    if (m <= 0.0f || m >= 1.0f) m = 0.5f;
    return (l <= m) ? 0.5f * l / m : 0.5f + 0.5f * (l - m) / (1.0f - m);
}

inline float smoothstep(float e0, float e1, float x) {
    const float t = saturate((x - e0) / (e1 - e0));
    return t * t * (3.0f - 2.0f * t);
}

// Rows are the unit of work, handed out in chunks from one counter: a pixel's
// result never depends on which thread computed it or on its neighbours.
template <class RowFn>
void forRows(int height, int threads, const RowFn& row) {
    constexpr int chunk = 16;
    const int chunks = (height + chunk - 1) / chunk;
    int workers = threads > 0 ? threads : int(std::thread::hardware_concurrency());
    workers = std::clamp(workers, 1, std::max(chunks, 1));
    if (workers == 1) {
        for (int y = 0; y < height; ++y) row(y);
        return;
    }
    std::atomic<int> next{0};
    auto work = [&] {
        for (int c = next.fetch_add(1); c < chunks; c = next.fetch_add(1))
            for (int y = c * chunk, end = std::min(height, y + chunk); y < end; ++y) row(y);
    };
    std::vector<std::thread> pool;
    pool.reserve(size_t(workers - 1));
    for (int i = 1; i < workers; ++i) pool.emplace_back(work);
    work();
    for (auto& t : pool) t.join();
}

[[noreturn]] void fail(const QString& message) { throw std::runtime_error(message.toUtf8().toStdString()); }

const Field& field(const char* path) {
    for (const auto& f : fields())
        if (qstrcmp(f.path, path) == 0) return f;
    fail(QStringLiteral("Post-Dev has no field ") + QLatin1String(path));
}

// The store's strictness (EditStore.cpp:70-105), with every key optional.
struct Reader {
    QStringList* unknown;

    void keys(const QJsonObject& object, std::initializer_list<const char*> known, const QString& label) const {
        for (auto it = object.begin(); it != object.end(); ++it) {
            const bool isKnown = std::any_of(known.begin(), known.end(),
                                             [&](const char* k) { return it.key() == QLatin1String(k); });
            if (isKnown) continue;
            if (!unknown) fail(QStringLiteral("Saved edits contain missing or unsupported fields in ") + label);
            unknown->append(label + "." + it.key());
        }
    }
    static QString path(const QString& label, const char* key) { return label + "." + QLatin1String(key); }
    double number(const QJsonObject& object, const char* key, const QString& label, const char* fieldPath) const {
        const auto& f = field(fieldPath);
        if (!object.contains(QLatin1String(key))) return f.initial;
        const auto value = object.value(QLatin1String(key));
        if (!value.isDouble()) fail(QStringLiteral("Saved edit field must be numeric: ") + path(label, key));
        const double result = value.toDouble();
        if (!std::isfinite(result) || result < f.low || result > f.high)
            fail(QStringLiteral("Saved edit field is outside its valid range: ") + path(label, key));
        return result;
    }
    bool boolean(const QJsonObject& object, const char* key, const QString& label, bool fallback) const {
        if (!object.contains(QLatin1String(key))) return fallback;
        const auto value = object.value(QLatin1String(key));
        if (!value.isBool()) fail(QStringLiteral("Saved edit field must be true or false: ") + path(label, key));
        return value.toBool();
    }
    std::optional<QJsonObject> object(const QJsonObject& parent, const char* key, const QString& label) const {
        if (!parent.contains(QLatin1String(key))) return std::nullopt;
        const auto value = parent.value(QLatin1String(key));
        if (!value.isObject()) fail(QStringLiteral("Saved edit field must be an object: ") + path(label, key));
        return value.toObject();
    }
    Curve curve(const QJsonObject& object, const QString& label) const {
        keys(object, {"points"}, label);
        if (!object.contains(QStringLiteral("points"))) fail(QStringLiteral("Saved edits are missing ") + label + ".points");
        const auto value = object.value(QStringLiteral("points"));
        const QString name = label + ".points";
        if (!value.isArray()) fail(QStringLiteral("Saved edit field must be a list of [x, y] points: ") + name);
        const auto list = value.toArray();
        if (list.size() < 2 || list.size() > Curve::maxPoints)
            fail(QStringLiteral("Saved edit curve must have 2 to %1 points: ").arg(Curve::maxPoints) + name);
        Curve curve;
        curve.points.clear();
        for (const auto& entry : list) {
            const auto pair = entry.toArray();
            if (!entry.isArray() || pair.size() != 2 || !pair[0].isDouble() || !pair[1].isDouble())
                fail(QStringLiteral("Saved edit field must be a list of [x, y] points: ") + name);
            const double x = pair[0].toDouble(), y = pair[1].toDouble();
            if (!std::isfinite(x) || !std::isfinite(y) || x < 0 || x > 1 || y < 0 || y > 1)
                fail(QStringLiteral("Saved edit curve point is outside the unit square: ") + name);
            if (!curve.points.empty() && x < curve.points.back().x)
                fail(QStringLiteral("Saved edit curve points must be sorted by x: ") + name);
            curve.points.push_back({x, y});
        }
        if (curve.points.front().x != 0 || curve.points.back().x != 1)
            fail(QStringLiteral("Saved edit curve must run from x = 0 to x = 1: ") + name);
        return curve;
    }
    ColorZone zone(const QJsonObject& object, const QString& label, const char* name) const {
        keys(object, {"hue", "saturation", "luminance"}, label);
        const QByteArray base = QByteArray("colorBalance.") + name + ".";
        return {number(object, "hue", label, (base + "hue").constData()),
                number(object, "saturation", label, (base + "saturation").constData()),
                number(object, "luminance", label, (base + "luminance").constData())};
    }
};

QJsonObject curveJson(const Curve& curve) {
    QJsonArray points;
    for (const auto& p : curve.points) points.append(QJsonArray{p.x, p.y});
    return {{QStringLiteral("points"), points}};
}
QJsonObject zoneJson(const ColorZone& z) {
    return {{QStringLiteral("hue"), z.hue}, {QStringLiteral("saturation"), z.saturation},
            {QStringLiteral("luminance"), z.luminance}};
}

} // namespace

// --- curves --------------------------------------------------------------------

bool Curve::isIdentity() const { return points == Curve{}.points; }

// CurveMath.swift:105-137, operation for operation.
double Curve::evaluate(double x) const {
    const auto& p = points;
    const int n = int(p.size());
    if (n < 2) return x;
    if (x <= p[0].x) return p[0].y;
    if (x >= p[n - 1].x) return p[n - 1].y;
    // Secants and tangents.
    std::vector<double> d(size_t(n - 1)), m(size_t(n), 0.0);
    for (int i = 0; i < n - 1; ++i) {
        const double dx = std::max(p[i + 1].x - p[i].x, 1e-6);
        d[i] = (p[i + 1].y - p[i].y) / dx;
    }
    m[0] = d[0];
    m[n - 1] = d[n - 2];
    for (int i = 1; i < n - 1; ++i) m[i] = (d[i - 1] * d[i] <= 0) ? 0 : (d[i - 1] + d[i]) / 2;
    // Fritsch-Carlson, in place and in order: a tangent limited on segment i
    // is the one segment i + 1 tests.
    for (int i = 0; i < n - 1; ++i) {
        if (d[i] == 0) continue;
        const double a = m[i] / d[i], b = m[i + 1] / d[i];
        const double s = a * a + b * b;
        if (s > 9) {
            const double t = 3 / std::sqrt(s);
            m[i] = t * a * d[i];
            m[i + 1] = t * b * d[i];
        }
    }
    // Locate the segment.
    int i = 0;
    while (i < n - 2 && x > p[i + 1].x) ++i;
    const double h = std::max(p[i + 1].x - p[i].x, 1e-6);
    const double t = (x - p[i].x) / h;
    const double t2 = t * t, t3 = t2 * t;
    const double h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t;
    const double h01 = -2 * t3 + 3 * t2, h11 = t3 - t2;
    const double y = h00 * p[i].y + h10 * h * m[i] + h01 * p[i + 1].y + h11 * h * m[i + 1];
    return std::clamp(y, 0.0, 1.0);
}

double Curve::hitTolerance(double width, double height) {
    const double side = std::min(width, height);
    return side > 0 ? 10 / side : 0;
}

std::optional<int> Curve::indexNear(CurvePoint p, double tolerance) const {
    std::optional<int> best;
    double bestDistance = 0;
    for (int i = 0; i < int(points.size()); ++i) {
        const double d = std::hypot(points[i].x - p.x, points[i].y - p.y);
        if (d <= tolerance && (!best || d < bestDistance)) { best = i; bestDistance = d; }
    }
    return best;
}

bool Curve::isDeletable(int i) const { return points.size() > 2 && i > 0 && i < int(points.size()) - 1; }

// The Mac has no cap; this one stops at maxPoints so that every curve the
// editor can make is one the store will save.
int Curve::insert(CurvePoint p) {
    if (int(points.size()) >= maxPoints) return -1;
    const CurvePoint q{std::clamp(p.x, 0.0, 1.0), std::clamp(p.y, 0.0, 1.0)};
    const auto at = std::find_if(points.begin(), points.end(), [&](const CurvePoint& c) { return c.x > q.x; });
    const int index = int(at - points.begin());
    points.insert(at, q);
    return index;
}

void Curve::move(int i, CurvePoint p) {
    if (i < 0 || i >= int(points.size())) return;
    CurvePoint q{std::clamp(p.x, 0.0, 1.0), std::clamp(p.y, 0.0, 1.0)};
    if (i == 0) q.x = 0;
    else if (i == int(points.size()) - 1) q.x = 1;
    else {
        const double lo = points[i - 1].x + 0.01, hi = points[i + 1].x - 0.01;
        q.x = std::clamp(q.x, std::min(lo, hi), std::max(lo, hi));
    }
    points[i] = q;
}

void Curve::remove(int i) {
    if (isDeletable(i)) points.erase(points.begin() + i);
}

Curve& CurveSet::operator[](CurveChannel channel) {
    switch (channel) {
    case CurveChannel::rgb: return rgb;
    case CurveChannel::luma: return luma;
    case CurveChannel::red: return red;
    case CurveChannel::green: return green;
    case CurveChannel::blue: break;
    }
    return blue;
}
const Curve& CurveSet::operator[](CurveChannel channel) const {
    return const_cast<CurveSet&>(*this)[channel];
}
bool CurveSet::isIdentity() const {
    return rgb.isIdentity() && luma.isIdentity() && red.isIdentity() && green.isIdentity() && blue.isIdentity();
}

CurveTables curveTables(const CurveSet& curves) {
    CurveTables out{};
    for (int row = 0; row < 5; ++row) {
        const auto& curve = curves[CurveChannel(row)];
        for (int i = 0; i < curveTableSize; ++i)
            out[size_t(row * curveTableSize + i)] = float(curve.evaluate(double(i) / double(curveTableSize - 1)));
    }
    return out;
}

float curveLookup(const float* row, float x) {
    float p = x * 256.0f - 0.5f;
    p = p > 0.0f ? (p < 255.0f ? p : 255.0f) : 0.0f;
    const float i = std::min(std::floor(p), 254.0f);
    const int k = int(i);
    const float f = p - i;
    return row[k] * (1.0f - f) + row[k + 1] * f;
}

// --- the model -----------------------------------------------------------------

std::array<float, 3> ColorZone::rgbOffset() const {
    constexpr double pi = std::numbers::pi;
    const double h = hue * pi / 180;
    const double r = std::cos(h), g = std::cos(h - 2 * pi / 3), b = std::cos(h + 2 * pi / 3);
    const float s = float(saturation) * 0.25f;
    return {float(r) * s, float(g) * s, float(b) * s};
}

bool ColorBalance::isNeutral() const {
    return master.isNeutral() && shadows.isNeutral() && midtones.isNeutral() && highlights.isNeutral();
}

bool Params::isNeutral() const {
    Params defaults;
    defaults.enabled = enabled;
    return *this == defaults;
}

const std::vector<Field>& fields() {
    // Hue 0..360, saturation 0..1, luminance -1..1 per zone (AgentSchema.swift:
    // 220-226, ColorWheel.swift:181-184). The vignette's midpoint has no
    // slider on the Mac, only the agent's field.
    static const std::vector<Field> table{
        {"temperature", -100, 100, 0, 5}, {"tint", -100, 100, 0, 5},
        {"exposure", -3, 3, 0, 0.25}, {"contrast", -50, 50, 0, 5}, {"brightness", -50, 50, 0, 5},
        {"saturation", -100, 100, 0, 5}, {"highlights", -100, 100, 0, 5}, {"shadows", -100, 100, 0, 5},
        {"blackPoint", 0, 50, 0, 1}, {"whitePoint", 0, 50, 0, 1},
        {"vignette.amount", -100, 100, 0, 5}, {"vignette.midpoint", 0, 100, 50, 0},
        {"colorBalance.master.hue", 0, 360, 0, 0}, {"colorBalance.master.saturation", 0, 1, 0, 0},
        {"colorBalance.master.luminance", -1, 1, 0, 0},
        {"colorBalance.shadows.hue", 0, 360, 0, 0}, {"colorBalance.shadows.saturation", 0, 1, 0, 0},
        {"colorBalance.shadows.luminance", -1, 1, 0, 0},
        {"colorBalance.midtones.hue", 0, 360, 0, 0}, {"colorBalance.midtones.saturation", 0, 1, 0, 0},
        {"colorBalance.midtones.luminance", -1, 1, 0, 0},
        {"colorBalance.highlights.hue", 0, 360, 0, 0}, {"colorBalance.highlights.saturation", 0, 1, 0, 0},
        {"colorBalance.highlights.luminance", -1, 1, 0, 0}};
    return table;
}

// --- uniforms --------------------------------------------------------------------

std::optional<float> midGreyFor(const QColorSpace& space) {
    if (!space.isValid()) return std::nullopt;
    switch (space.transferFunction()) {
    case QColorSpace::TransferFunction::ProPhotoRgb: return proPhotoMidGrey;
    case QColorSpace::TransferFunction::SRgb: return srgbMidGrey;
    case QColorSpace::TransferFunction::Gamma:
        // A pure 1.8 curve differs from ROMM's only below 1/512.
        if (std::abs(space.gamma() - 1.8f) < 1e-6f) return proPhotoMidGrey;
        return std::nullopt;
    default: return std::nullopt;
    }
}

// Adjustments.swift:72-94 and Mask.swift:301-324, in Float as Swift does it.
Uniforms uniforms(const Params& p, float midGrey) {
    Uniforms u;
    const float t = float(p.temperature) / 100.0f, g = float(p.tint) / 100.0f;
    u.wbGain = {1.0f + 0.18f * t, 1.0f - 0.12f * g, 1.0f - 0.18f * t};
    u.exposureGain = float(std::pow(2.0, p.exposure));
    // pow(pow(x, 2.2) * g, 1/2.2) == x * g^(1/2.2) for x >= 0 (Shaders.metal:
    // 274-277): one multiply per channel instead of two pows, on both paths.
    u.exposureScale = float(std::pow(double(u.exposureGain), 1.0 / 2.2));
    u.contrast = float(p.contrast) / 100.0f;
    u.brightness = float(p.brightness) / 100.0f;
    u.saturation = 1.0f + float(p.saturation) / 100.0f;
    u.highlights = float(p.highlights) / 100.0f;
    u.shadows = float(p.shadows) / 100.0f;
    u.blackPoint = float(p.blackPoint) / 100.0f;
    u.whitePoint = float(p.whitePoint) / 100.0f;
    u.midGrey = midGrey;
    const auto& cb = p.colorBalance;
    u.cbMaster = cb.master.rgbOffset();
    u.cbShadows = cb.shadows.rgbOffset();
    u.cbMidtones = cb.midtones.rgbOffset();
    u.cbHighlights = cb.highlights.rgbOffset();
    u.cbLum = {float(cb.master.luminance) * 0.25f, float(cb.shadows.luminance) * 0.25f,
               float(cb.midtones.luminance) * 0.25f, float(cb.highlights.luminance) * 0.25f};
    u.vignetteAmount = float(p.vignette.amount) / 100.0f;
    u.vignetteMidpoint = float(p.vignette.midpoint) / 100.0f;
    u.curvesActive = !p.curves.isIdentity();
    u.enabled = p.enabled;
    return u;
}

bool isIdentity(const Uniforms& u) {
    if (!u.enabled) return true;
    const auto zero3 = [](const std::array<float, 3>& v) { return v[0] == 0 && v[1] == 0 && v[2] == 0; };
    return u.wbGain[0] == 1 && u.wbGain[1] == 1 && u.wbGain[2] == 1 && u.exposureGain == 1 &&
           u.contrast == 0 && u.brightness == 0 && u.saturation == 1 && u.highlights == 0 &&
           u.shadows == 0 && u.blackPoint == 0 && u.whitePoint == 0 && zero3(u.cbMaster) &&
           zero3(u.cbShadows) && zero3(u.cbMidtones) && zero3(u.cbHighlights) && u.cbLum[0] == 0 &&
           u.cbLum[1] == 0 && u.cbLum[2] == 0 && u.cbLum[3] == 0 && u.vignetteAmount == 0 && !u.curvesActive;
}

// --- the CPU path ----------------------------------------------------------------

Grade::Grade(const Params& params, float midGrey)
    : Grade(postdev::uniforms(params, midGrey), curveTables(params.curves)) {}

Grade::Grade(const Uniforms& uniforms, const CurveTables& tables)
    : u_(uniforms), tables_(tables), identity_(postdev::isIdentity(uniforms)) {}

// layer2Tone, Shaders.metal:270-313, in its order and its float arithmetic.
std::array<float, 3> Grade::tone(std::array<float, 3> c) const {
    const auto& u = u_;
    // 1. white balance (scan-side gains on encoded values)
    for (int i = 0; i < 3; ++i) c[i] *= u.wbGain[i];
    // 2. exposure in a pseudo-linear domain, then contrast and brightness
    if (u.exposureGain != 1.0f)
        for (auto& v : c) v = positive(v) * u.exposureScale;
    if (u.contrast != 0.0f) {
        const float k = 1.0f + u.contrast * 1.2f;
        for (auto& v : c) v = (v - u.midGrey) * k + u.midGrey;
    }
    if (u.brightness != 0.0f) {
        const float e = 1.0f / (1.0f + u.brightness * 0.8f);
        for (auto& v : c) v = std::pow(positive(v), e);
    }
    // 3. highlights / shadows, measured from mid-grey
    float l = tonePosition(luma(c), u.midGrey);
    if (u.shadows != 0.0f) {
        float w = 1.0f - l;
        w = w * w;
        const float k = u.shadows * 0.25f * w;
        for (auto& v : c) v += k * (1.0f - v);
    }
    if (u.highlights != 0.0f) {
        const float w = l * l;
        const float k = u.highlights * 0.25f * w;
        for (auto& v : c) v += k * (u.highlights > 0 ? (1.0f - v) : v);
    }
    // 4. black / white point
    const float span = std::max(1.0f - u.blackPoint - u.whitePoint, 0.05f);
    for (auto& v : c) v = (v - u.blackPoint) / span;
    // 5. saturation
    l = luma(c);
    for (auto& v : c) v = l + (v - l) * u.saturation;
    // 6. colour balance: master + three zones split at mid-grey
    const float ls = saturate(tonePosition(l, u.midGrey));
    const float wS = (1.0f - ls) * (1.0f - ls);
    const float wH = ls * ls;
    const float wM = std::max(1.0f - wS - wH, 0.0f);
    for (int i = 0; i < 3; ++i)
        c[i] += u.cbMaster[i] + u.cbShadows[i] * wS + u.cbMidtones[i] * wM + u.cbHighlights[i] * wH;
    const float lum = 1.0f + u.cbLum[0] + u.cbLum[1] * wS + u.cbLum[2] * wM + u.cbLum[3] * wH;
    for (auto& v : c) v *= lum;
    return c;
}

// The rest of the kernel, Shaders.metal:350-403 (no masks, no DI decode).
std::array<float, 3> Grade::pixel(std::array<float, 3> rgb, float u, float v) const {
    if (identity_) return rgb;
    auto c = tone(rgb);
    // 7. curves -- luma, then RGB master, then per channel
    if (u_.curvesActive) {
        const float* rows = tables_.data();
        for (auto& x : c) x = saturate(x);
        const float ly = luma(c);
        const float ly2 = curveLookup(rows + curveTableSize, ly);
        const float k = (ly > 1e-4f) ? (ly2 / ly) : 1.0f;
        for (auto& x : c) x = saturate(x * k);
        for (auto& x : c) x = curveLookup(rows, x);
        c = {curveLookup(rows + 2 * curveTableSize, c[0]), curveLookup(rows + 3 * curveTableSize, c[1]),
             curveLookup(rows + 4 * curveTableSize, c[2])};
    }
    // 9. vignette -- radial about the source's centre, per axis
    if (u_.vignetteAmount != 0.0f) {
        const float px = (u - 0.5f) * 2.0f, py = (v - 0.5f) * 2.0f;
        const float d = std::sqrt(px * px + py * py);
        const float fall = smoothstep(u_.vignetteMidpoint * 1.2f, 1.5f, d);
        const float k = 1.0f + u_.vignetteAmount * fall * 0.9f;
        for (auto& x : c) x *= k;
    }
    for (auto& x : c) x = saturate(x);
    return c;
}

void Grade::apply(float* data, int width, int height, int channels, std::ptrdiff_t rowStride, int threads,
                  SourceRect source) const {
    if (channels != 3 && channels != 4) throw std::invalid_argument("Post-Dev applies to 3 or 4 channels");
    if (width < 0 || height < 0) throw std::invalid_argument("Post-Dev image size is negative");
    if (identity_ || width == 0 || height == 0) return;
    if (rowStride == 0) rowStride = std::ptrdiff_t(width) * channels;
    const float sx = float(source.x), sy = float(source.y), sw = float(source.width), sh = float(source.height);
    const float fw = float(width), fh = float(height);
    forRows(height, threads, [&](int y) {
        float* row = data + std::ptrdiff_t(y) * rowStride;
        // (gid + 0.5) / size, Shaders.metal:340, in float.
        const float v = sy + (float(y) + 0.5f) / fh * sh;
        for (int x = 0; x < width; ++x) {
            float* p = row + std::ptrdiff_t(x) * channels;
            const auto out = pixel({p[0], p[1], p[2]}, sx + (float(x) + 0.5f) / fw * sw, v);
            p[0] = out[0];
            p[1] = out[1];
            p[2] = out[2];
        }
    });
}

void Grade::apply(QImage& image, int threads, SourceRect source) const {
    const auto format = image.format();
    enum class Kind { u16, f32, u8rgba, u8argb } kind;
    switch (format) {
    case QImage::Format_RGBX64: case QImage::Format_RGBA64: kind = Kind::u16; break;
    case QImage::Format_RGBX32FPx4: case QImage::Format_RGBA32FPx4: kind = Kind::f32; break;
    case QImage::Format_RGBX8888: case QImage::Format_RGBA8888: kind = Kind::u8rgba; break;
    case QImage::Format_RGB32: case QImage::Format_ARGB32: kind = Kind::u8argb; break;
    default: throw std::invalid_argument("Post-Dev cannot grade this QImage format; convert it first");
    }
    if (identity_ || image.isNull()) return;
    const int width = image.width(), height = image.height();
    const qsizetype stride = image.bytesPerLine();
    uchar* bits = image.bits();
    const float sx = float(source.x), sy = float(source.y), sw = float(source.width), sh = float(source.height);
    const float fw = float(width), fh = float(height);
    forRows(height, threads, [&](int y) {
        uchar* line = bits + qsizetype(y) * stride;
        const float v = sy + (float(y) + 0.5f) / fh * sh;
        for (int x = 0; x < width; ++x) {
            const float u = sx + (float(x) + 0.5f) / fw * sw;
            switch (kind) {
            case Kind::u16: {
                auto* p = reinterpret_cast<quint16*>(line) + 4 * x;
                const auto out = pixel({p[0] / 65535.0f, p[1] / 65535.0f, p[2] / 65535.0f}, u, v);
                for (int i = 0; i < 3; ++i) p[i] = quint16(out[i] * 65535.0f + 0.5f);
                break;
            }
            case Kind::f32: {
                auto* p = reinterpret_cast<float*>(line) + 4 * x;
                const auto out = pixel({p[0], p[1], p[2]}, u, v);
                for (int i = 0; i < 3; ++i) p[i] = out[i];
                break;
            }
            case Kind::u8rgba: {
                uchar* p = line + 4 * x;
                const auto out = pixel({p[0] / 255.0f, p[1] / 255.0f, p[2] / 255.0f}, u, v);
                for (int i = 0; i < 3; ++i) p[i] = uchar(out[i] * 255.0f + 0.5f);
                break;
            }
            case Kind::u8argb: {
                auto* p = reinterpret_cast<QRgb*>(line) + x;
                const auto out = pixel({qRed(*p) / 255.0f, qGreen(*p) / 255.0f, qBlue(*p) / 255.0f}, u, v);
                *p = qRgba(int(out[0] * 255.0f + 0.5f), int(out[1] * 255.0f + 0.5f),
                           int(out[2] * 255.0f + 0.5f), qAlpha(*p));
                break;
            }
            }
        }
    });
}

// --- the GPU block -----------------------------------------------------------------

std::array<float, std140Bytes / sizeof(float)> std140(const Grade& grade) {
    const auto& u = grade.uniforms();
    const float on = grade.isIdentity() ? 0.0f : 1.0f;
    return {u.wbGain[0], u.wbGain[1], u.wbGain[2], u.exposureScale,
            u.contrast, u.brightness, u.saturation, u.highlights,
            u.shadows, u.blackPoint, u.whitePoint, u.midGrey,
            u.cbMaster[0], u.cbMaster[1], u.cbMaster[2], 0.0f,
            u.cbShadows[0], u.cbShadows[1], u.cbShadows[2], 0.0f,
            u.cbMidtones[0], u.cbMidtones[1], u.cbMidtones[2], 0.0f,
            u.cbHighlights[0], u.cbHighlights[1], u.cbHighlights[2], 0.0f,
            u.cbLum[0], u.cbLum[1], u.cbLum[2], u.cbLum[3],
            u.vignetteAmount, u.vignetteMidpoint, 0.0f, 0.0f,
            on, u.curvesActive ? 1.0f : 0.0f, u.exposureGain != 1.0f ? 1.0f : 0.0f, 0.0f};
}

// --- JSON ------------------------------------------------------------------------

QJsonObject toJson(const Params& p) {
    const auto& c = p.curves;
    const auto& cb = p.colorBalance;
    return {
        {QStringLiteral("enabled"), p.enabled},
        {QStringLiteral("temperature"), p.temperature},
        {QStringLiteral("tint"), p.tint},
        {QStringLiteral("exposure"), p.exposure},
        {QStringLiteral("contrast"), p.contrast},
        {QStringLiteral("brightness"), p.brightness},
        {QStringLiteral("saturation"), p.saturation},
        {QStringLiteral("highlights"), p.highlights},
        {QStringLiteral("shadows"), p.shadows},
        {QStringLiteral("blackPoint"), p.blackPoint},
        {QStringLiteral("whitePoint"), p.whitePoint},
        {QStringLiteral("curves"), QJsonObject{{QStringLiteral("rgb"), curveJson(c.rgb)},
                                               {QStringLiteral("luma"), curveJson(c.luma)},
                                               {QStringLiteral("red"), curveJson(c.red)},
                                               {QStringLiteral("green"), curveJson(c.green)},
                                               {QStringLiteral("blue"), curveJson(c.blue)}}},
        {QStringLiteral("colorBalance"), QJsonObject{{QStringLiteral("master"), zoneJson(cb.master)},
                                                     {QStringLiteral("shadows"), zoneJson(cb.shadows)},
                                                     {QStringLiteral("midtones"), zoneJson(cb.midtones)},
                                                     {QStringLiteral("highlights"), zoneJson(cb.highlights)}}},
        {QStringLiteral("vignette"), QJsonObject{{QStringLiteral("amount"), p.vignette.amount},
                                                 {QStringLiteral("midpoint"), p.vignette.midpoint}}},
    };
}

Params fromJson(const QJsonObject& o, QStringList* unknown, const QString& label) {
    const Reader r{unknown};
    r.keys(o, {"enabled", "temperature", "tint", "exposure", "contrast", "brightness", "saturation",
               "highlights", "shadows", "blackPoint", "whitePoint", "curves", "colorBalance", "vignette"},
           label);
    Params p;
    p.enabled = r.boolean(o, "enabled", label, true);
    p.temperature = r.number(o, "temperature", label, "temperature");
    p.tint = r.number(o, "tint", label, "tint");
    p.exposure = r.number(o, "exposure", label, "exposure");
    p.contrast = r.number(o, "contrast", label, "contrast");
    p.brightness = r.number(o, "brightness", label, "brightness");
    p.saturation = r.number(o, "saturation", label, "saturation");
    p.highlights = r.number(o, "highlights", label, "highlights");
    p.shadows = r.number(o, "shadows", label, "shadows");
    p.blackPoint = r.number(o, "blackPoint", label, "blackPoint");
    p.whitePoint = r.number(o, "whitePoint", label, "whitePoint");
    if (const auto curves = r.object(o, "curves", label)) {
        const QString at = label + QStringLiteral(".curves");
        r.keys(*curves, {"rgb", "luma", "red", "green", "blue"}, at);
        const std::pair<const char*, CurveChannel> channels[] = {
            {"rgb", CurveChannel::rgb}, {"luma", CurveChannel::luma}, {"red", CurveChannel::red},
            {"green", CurveChannel::green}, {"blue", CurveChannel::blue}};
        for (const auto& [name, channel] : channels)
            if (const auto curve = r.object(*curves, name, at))
                p.curves[channel] = r.curve(*curve, at + "." + QLatin1String(name));
    }
    if (const auto balance = r.object(o, "colorBalance", label)) {
        const QString at = label + QStringLiteral(".colorBalance");
        r.keys(*balance, {"master", "shadows", "midtones", "highlights"}, at);
        const std::pair<const char*, ColorZone ColorBalance::*> zones[] = {
            {"master", &ColorBalance::master}, {"shadows", &ColorBalance::shadows},
            {"midtones", &ColorBalance::midtones}, {"highlights", &ColorBalance::highlights}};
        for (const auto& [name, member] : zones)
            if (const auto zone = r.object(*balance, name, at))
                p.colorBalance.*member = r.zone(*zone, at + "." + QLatin1String(name), name);
    }
    if (const auto vignette = r.object(o, "vignette", label)) {
        const QString at = label + QStringLiteral(".vignette");
        r.keys(*vignette, {"amount", "midpoint"}, at);
        p.vignette.amount = r.number(*vignette, "amount", at, "vignette.amount");
        p.vignette.midpoint = r.number(*vignette, "midpoint", at, "vignette.midpoint");
    }
    return p;
}

// --- the wheel -----------------------------------------------------------------

namespace wheel {
namespace {
constexpr double sweep = 130;
double bottomTheta(Side side) { return side == Side::left ? 245 : -65; }
double topTheta(Side side) { return side == Side::left ? 245 - sweep : -65 + sweep; }
} // namespace

ColorZone zoneAt(double x, double y, double diameter, ColorZone zone) {
    const double c = diameter / 2, radius = diameter / 2 - 5;
    const double dx = x - c, dy = c - y;
    const double distance = std::hypot(dx, dy);
    const double rr = radius > 0 ? std::min(distance / radius, 1.0) : (distance > 0 ? 1.0 : 0.0);
    double deg = std::atan2(dy, dx) * 180 / std::numbers::pi;
    if (deg < 0) deg += 360;
    zone.hue = deg;
    zone.saturation = rr;
    return zone;
}

std::pair<double, double> pointOf(const ColorZone& zone, double diameter) {
    const double r = zone.saturation * (diameter / 2 - 5);
    const double a = zone.hue * std::numbers::pi / 180;
    return {diameter / 2 + std::cos(a) * r, diameter / 2 - std::sin(a) * r};
}

double arcTheta(double fraction, Side side) {
    const double f = std::clamp(fraction, 0.0, 1.0);
    return bottomTheta(side) + (topTheta(side) - bottomTheta(side)) * f;
}

double arcAngle(double px, double py, double cx, double cy) {
    const double theta = std::atan2(cy - py, px - cx) * 180 / std::numbers::pi;
    return theta > 180 ? theta - 360 : theta;
}

double arcValue(double thetaDegrees, Side side, double low, double high) {
    const double bottom = bottomTheta(side), top = topTheta(side);
    const double mid = (bottom + top) / 2;
    double t = thetaDegrees;
    while (t - mid > 180) t -= 360;
    while (t - mid < -180) t += 360;
    const double f = std::clamp((t - bottom) / (top - bottom), 0.0, 1.0);
    return low + f * (high - low);
}

double arcFraction(double value, double low, double high) {
    return std::clamp((value - low) / std::max(high - low, 1e-9), 0.0, 1.0);
}
} // namespace wheel

} // namespace spk::desktop::postdev
