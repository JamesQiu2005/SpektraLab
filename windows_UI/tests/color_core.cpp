// The colour core on the CPU. Every ICC profile is made here, from Qt's own
// colour spaces or byte by byte; the LUT is held to Qt's transform through the
// model of the shader's lookup (ColorLut.hpp); simulated monitors drive the
// real ColorPipeline. No GPU, no shown window, no installed profile is read.
//
// `--probe-display` instead prints what the Windows queries say about this
// machine's monitors; it reads, and changes nothing. `--sweep` prints the
// measurements kLinearTableSize and kCurveSize were chosen from.
#include "ColorLut.hpp"
#include "ColorPipeline.hpp"
#include "DisplayColor.hpp"

#include <QColorTransform>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QGuiApplication>
#include <QQuickWindow>
#include <QRgbaFloat>
#include <QScreen>
#include <QThread>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <functional>
#include <map>
#include <random>
#include <stdexcept>
#include <vector>

namespace color = spk::color;

namespace {
int checks = 0;
void check(bool value, const QString& message) {
    ++checks;
    if (!value) throw std::runtime_error(message.toStdString());
}
void say(const QString& line) {
    std::printf("%s\n", qPrintable(line));
    std::fflush(stdout);
}
QString counts(double value) { return QString::number(value * 255.0, 'f', 3) + QStringLiteral(" counts"); }

// Half an 8-bit count: an error below it cannot change a quantised pixel.
constexpr double kBar = 0.5 / 255.0;

float clamp01(float v) { return std::clamp(v, 0.0f, 1.0f); }
double srgbToLinear(double c) { return c <= 0.04045 ? c / 12.92 : std::pow((c + 0.055) / 1.055, 2.4); }

QByteArray iccOf(const QColorSpace& space) {
    const QByteArray bytes = space.iccProfile();
    check(!bytes.isEmpty(), QStringLiteral("Qt wrote no ICC profile for %1").arg(space.description()));
    return bytes;
}
// What a display would hand over: the profile's bytes, read back.
QColorSpace viaIcc(const QColorSpace& space) {
    const QColorSpace parsed = QColorSpace::fromIccProfile(iccOf(space));
    check(parsed.isValid() && parsed.isValidTarget(), QStringLiteral("%1 does not survive an ICC round trip").arg(space.description()));
    return parsed;
}
// This machine's display profile as the probe reads it ("HP Z31x AdobeRGB D65
// Display Profile": these primaries, D65, a pure gamma 2.2), so the case that
// missed by 7.2 counts on the real display is held in CTest too.
QColorSpace hpZ31xReplica() {
    return viaIcc(QColorSpace(QPointF(0.3127, 0.3290), QPointF(0.64, 0.34), QPointF(0.21, 0.71), QPointF(0.15, 0.06),
                              QColorSpace::TransferFunction::Gamma, 2.2f));
}

// --- ICC profiles Qt cannot write: A2B-only, A2B/B2A-only and CMYK.
void putU32(QByteArray& b, quint32 v) {
    const char bytes[4] = {char(v >> 24), char(v >> 16), char(v >> 8), char(v)};
    b.append(bytes, 4);
}
void putU16(QByteArray& b, quint16 v) {
    const char bytes[2] = {char(v >> 8), char(v)};
    b.append(bytes, 2);
}
void putSig(QByteArray& b, const char* sig) { b.append(sig, 4); }
void putFixed(QByteArray& b, double v) { putU32(b, quint32(qint32(std::lround(v * 65536.0)))); }
quint16 unit16(double v, double scale) { return quint16(std::clamp(std::lround(v * scale), 0l, 65535l)); }

QByteArray xyzType(double x, double y, double z) {
    QByteArray t;
    putSig(t, "XYZ ");
    putU32(t, 0);
    putFixed(t, x);
    putFixed(t, y);
    putFixed(t, z);
    return t;
}
QByteArray mlucType(const QString& text) {
    QByteArray t;
    putSig(t, "mluc");
    putU32(t, 0);
    putU32(t, 1);  // one record
    putU32(t, 12); // record size
    putSig(t, "enUS");
    putU32(t, quint32(text.size() * 2));
    putU32(t, 28); // the string follows the single record
    for (QChar c : text) putU16(t, c.unicode());
    return t;
}
// lut16Type: identity matrix, then per-channel input curves, a `grid`-point
// CLUT and output curves; `node` gives the 16-bit outputs at a grid point
// (first input slowest), the curves map [0, 1] to [0, 1] in `curveEntries`
// steps (identity by default).
QByteArray lut16Type(int inputs, int outputs, int grid,
                     const std::function<std::vector<quint16>(const std::vector<double>&)>& node,
                     int curveEntries = 2, const std::function<double(double)>& inputCurve = {},
                     const std::function<double(double)>& outputCurve = {}) {
    QByteArray t;
    putSig(t, "mft2");
    putU32(t, 0);
    t.append(char(inputs));
    t.append(char(outputs));
    t.append(char(grid));
    t.append('\0');
    for (int i = 0; i < 9; ++i) putFixed(t, i % 4 == 0 ? 1.0 : 0.0);
    putU16(t, quint16(curveEntries));
    putU16(t, quint16(curveEntries));
    const auto curve = [&](const std::function<double(double)>& f) {
        for (int e = 0; e < curveEntries; ++e) {
            const double x = double(e) / double(curveEntries - 1);
            putU16(t, unit16(f ? f(x) : x, 65535.0));
        }
    };
    for (int i = 0; i < inputs; ++i) curve(inputCurve);
    int total = 1;
    for (int i = 0; i < inputs; ++i) total *= grid;
    for (int index = 0; index < total; ++index) {
        std::vector<double> in(static_cast<std::size_t>(inputs), 0.0);
        int rest = index;
        for (int i = inputs - 1; i >= 0; --i) {
            in[std::size_t(i)] = double(rest % grid) / double(grid - 1);
            rest /= grid;
        }
        const auto out = node(in);
        check(int(out.size()) == outputs, QStringLiteral("CLUT node has the wrong channel count"));
        for (quint16 v : out) putU16(t, v);
    }
    for (int i = 0; i < outputs; ++i) curve(outputCurve);
    return t;
}
QByteArray buildIcc(const char* deviceClass, const char* space, const char* pcs,
                    const std::vector<std::pair<const char*, QByteArray>>& tags) {
    QByteArray header;
    putU32(header, 0);          // size, patched below
    putU32(header, 0);          // preferred CMM
    putU32(header, 0x04300000); // version 4.3
    putSig(header, deviceClass);
    putSig(header, space);
    putSig(header, pcs);
    for (quint16 v : {2026, 10, 16, 12, 0, 0}) putU16(header, v);
    putSig(header, "acsp");
    putSig(header, "MSFT");
    for (int i = 0; i < 6; ++i) putU32(header, 0); // flags, manufacturer, model, attributes, intent
    putFixed(header, 0.9642);
    putFixed(header, 1.0);
    putFixed(header, 0.8249);
    putU32(header, 0);                   // creator
    header.append(QByteArray(44, '\0')); // profile ID (not computed) and reserved
    check(header.size() == 128, QStringLiteral("ICC header is not 128 bytes"));
    QByteArray table, data;
    putU32(table, quint32(tags.size()));
    const int dataStart = 128 + 4 + 12 * int(tags.size());
    for (const auto& [sig, bytes] : tags) {
        putSig(table, sig);
        putU32(table, quint32(dataStart + data.size()));
        putU32(table, quint32(bytes.size()));
        data.append(bytes);
        while (data.size() % 4) data.append('\0');
    }
    QByteArray profile = header + table + data;
    const quint32 size = quint32(profile.size());
    for (int i = 0; i < 4; ++i) profile[i] = char(size >> (24 - 8 * i));
    return profile;
}

// A space's primaries as D50 XYZ (rows: R, G, B), adapted as Qt adapts them:
// through Qt into linear ProPhoto RGB (D50), then ROMM's published matrix.
using Primaries = std::array<std::array<double, 3>, 3>;
std::array<double, 3> rommToXyz(const QRgbaFloat32& p) {
    return {0.7977 * p.r + 0.1352 * p.g + 0.0313 * p.b, 0.2880 * p.r + 0.7119 * p.g + 0.0001 * p.b, 0.8249 * p.b};
}
Primaries primariesD50(QColorSpace::Primaries primaries) {
    const auto toRomm = QColorSpace(primaries, QColorSpace::TransferFunction::Linear)
                            .transformationToColorSpace(QColorSpace(QColorSpace::Primaries::ProPhotoRgb, QColorSpace::TransferFunction::Linear));
    Primaries m{};
    for (int i = 0; i < 3; ++i) m[std::size_t(i)] = rommToXyz(toRomm.map(QRgbaFloat32{i == 0 ? 1.0f : 0.0f, i == 1 ? 1.0f : 0.0f, i == 2 ? 1.0f : 0.0f, 1.0f}));
    return m;
}
// Solves xyz = sum rgb[i] * m[i] by Cramer's rule.
std::array<double, 3> xyzToRgb(const Primaries& m, const std::array<double, 3>& xyz) {
    const double a = m[0][0], b = m[1][0], c = m[2][0], d = m[0][1], e = m[1][1], f = m[2][1], g = m[0][2], h = m[1][2],
                 k = m[2][2];
    const double det = a * (e * k - f * h) - b * (d * k - f * g) + c * (d * h - e * g);
    return {((e * k - f * h) * xyz[0] - (b * k - c * h) * xyz[1] + (b * f - c * e) * xyz[2]) / det,
            (-(d * k - f * g) * xyz[0] + (a * k - c * g) * xyz[1] - (a * f - c * d) * xyz[2]) / det,
            ((d * h - e * g) * xyz[0] - (a * h - b * g) * xyz[1] + (a * e - b * d) * xyz[2]) / det};
}
// sRGB's primaries adapted to D50 (rows: R, G, B as XYZ), for the A2B-only profile.
constexpr double kSrgbD50[3][3] = {{0.4361, 0.2225, 0.0139}, {0.3851, 0.7169, 0.0971}, {0.1431, 0.0606, 0.7141}};

// An RGB display described only device -> PCS: valid as a source, never a target.
QByteArray a2bOnlyProfile() {
    return buildIcc("mntr", "RGB ", "XYZ ", {
        {"desc", mlucType(QStringLiteral("A2B-only RGB"))},
        {"cprt", mlucType(QStringLiteral("No copyright, test data"))},
        {"wtpt", xyzType(0.9642, 1.0, 0.8249)},
        {"A2B0", lut16Type(3, 3, 2, [](const std::vector<double>& rgb) {
             std::vector<quint16> xyz;
             for (int c = 0; c < 3; ++c) {
                 const double v = rgb[0] * kSrgbD50[0][c] + rgb[1] * kSrgbD50[1][c] + rgb[2] * kSrgbD50[2][c];
                 xyz.push_back(unit16(v, 32768.0)); // lut16 PCSXYZ: 1.0 is 0x8000
             }
             return xyz;
         })},
    });
}
// A wide-gamut display (Rec.2020 primaries, gamma 2.2) described only by
// lut16 tables both ways, built the way profilers build them: the curves in
// the 1D tables, the CLUTs nearly linear, a cube-root shaper before the B2A
// CLUT so its nodes sit where the eye needs them. Its gamut holds sRGB, so
// sRGB colours stay clear of the clipped region a B2A table must contain. A
// valid target with no 3x3 to factor out: it keeps the encoded-domain table.
//
// Qt 6.11.3 reads lut16 PCSXYZ with 0xFFFF as 1.0 (measured: white written
// at ICC's legacy 0x8000 came back as half the light), so this profile is
// written the way Qt reads it, to describe the display intended.
QByteArray lutDisplayProfile() {
    static const Primaries bt2020 = primariesD50(QColorSpace::Primaries::Bt2020);
    const auto decode = [](double v) { return std::pow(v, 2.2); };
    const auto encode = [](double v) { return std::pow(v, 1.0 / 2.2); };
    return buildIcc("mntr", "RGB ", "XYZ ", {
        {"desc", mlucType(QStringLiteral("LUT-based wide-gamut gamma 2.2 display"))},
        {"cprt", mlucType(QStringLiteral("No copyright, test data"))},
        {"wtpt", xyzType(0.9642, 1.0, 0.8249)},
        {"A2B0", lut16Type(3, 3, 17, [](const std::vector<double>& linear) {
             std::vector<quint16> xyz;
             for (std::size_t c = 0; c < 3; ++c) {
                 double v = 0;
                 for (std::size_t i = 0; i < 3; ++i) v += linear[i] * bt2020[i][c];
                 xyz.push_back(unit16(v, 65535.0));
             }
             return xyz;
         }, 4096, decode)},
        {"B2A0", lut16Type(3, 3, 17, [](const std::vector<double>& index) {
             std::vector<quint16> out;
             for (double v : xyzToRgb(bt2020, {std::pow(index[0], 3.0), std::pow(index[1], 3.0), std::pow(index[2], 3.0)}))
                 out.push_back(unit16(std::clamp(v, 0.0, 1.0), 65535.0));
             return out;
         }, 4096, [](double v) { return std::cbrt(v); }, encode)},
    });
}
QByteArray cmykProfile() {
    return buildIcc("prtr", "CMYK", "Lab ", {
        {"desc", mlucType(QStringLiteral("CMYK test"))},
        {"cprt", mlucType(QStringLiteral("No copyright, test data"))},
        {"wtpt", xyzType(0.9642, 1.0, 0.8249)},
        {"A2B0", lut16Type(4, 3, 2, [](const std::vector<double>& cmyk) {
             const double lightness = (1 - cmyk[0]) * (1 - cmyk[1]) * (1 - cmyk[2]) * (1 - cmyk[3]);
             // lut16 Lab: L* 100 is 0xFF00, a* = b* = 0 is 0x8000.
             return std::vector<quint16>{unit16(lightness, 65280.0), 0x8000, 0x8000};
         })},
    });
}

// --- the LUT against Qt's transform, through the model of the shader.

// CIELAB (D50) of what a display shows for an encoded RGB triple, through Qt
// into linear ProPhoto RGB and ROMM's published matrix. The perceptual
// yardstick beside 8-bit counts, which overstate an error in a channel near
// zero on a power-curve display (code 7 of 255 is 0.04 % of full light).
class Lab {
public:
    explicit Lab(const QColorSpace& display)
        : toRomm_(display.transformationToColorSpace(
              QColorSpace(QColorSpace::Primaries::ProPhotoRgb, QColorSpace::TransferFunction::Linear))) {}
    std::array<double, 3> operator()(float r, float g, float b) const {
        const QRgbaFloat32 p = toRomm_.map(QRgbaFloat32{clamp01(r), clamp01(g), clamp01(b), 1.0f});
        const double x = 0.7977 * p.r + 0.1352 * p.g + 0.0313 * p.b;
        const double y = 0.2880 * p.r + 0.7119 * p.g + 0.0001 * p.b;
        const double z = 0.8249 * p.b;
        const auto f = [](double t) { return t > 216.0 / 24389.0 ? std::cbrt(t) : (24389.0 / 27.0 * t + 16.0) / 116.0; };
        const double fx = f(x / 0.9642), fy = f(y), fz = f(z / 0.8249);
        return {116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz)};
    }
    double deltaE(const std::array<float, 3>& a, const std::array<float, 3>& b) const {
        const auto la = (*this)(a[0], a[1], a[2]), lb = (*this)(b[0], b[1], b[2]);
        return std::sqrt((la[0] - lb[0]) * (la[0] - lb[0]) + (la[1] - lb[1]) * (la[1] - lb[1]) + (la[2] - lb[2]) * (la[2] - lb[2]));
    }

private:
    QColorTransform toRomm_;
};

// Exact float filtering (the contract), then what a canvas may do instead:
// D3D11 and Vulkan promise only 8 bits of hardware filter-weight precision
// (NVIDIA documents 8 fractional bits, not whether it rounds), and entries may
// be uploaded as halves. Sampler 1 is ColorLut.hpp's recommendation -- all
// float32, curves on hardware filtering at its worst, the table with float
// weights -- and is held to the same bar as exact filtering; 2-5 are what the
// recommendation avoids, measured, not required.
constexpr int kSamplers = 6;
const color::LutSampling kSampling[kSamplers] = {{},
                                                 {8, true, true, false, false},
                                                 {8, false, false, false, false},
                                                 {8, true, false, false, false},
                                                 {0, false, false, false, true},
                                                 {0, false, false, true, false}};
const char* const kSamplerName[kSamplers] = {
    "exact filtering", "recommended canvas (float32; curves on truncated 8-bit weights; table on float weights)",
    "table on 8-bit weights, rounded", "table on 8-bit weights, truncated", "table in half floats", "curves in half floats"};
constexpr int kRequiredSamplers = 2;

struct Errors {
    double worst = 0;           // max over everything, in [0, 1] units
    double worstAwayFromBlack = 0; // max over samples with no channel at codes 1-3
    double worstDeltaE = 0;     // max CIE76 delta E*ab, when measured
    qint64 over = 0, samples = 0;
    int worstCode[3] = {0, 0, 0}, worstDeltaECode[3] = {0, 0, 0};
    void add(double error, int r, int g, int b, double deltaE = 0) {
        ++samples;
        if (error >= kBar) ++over;
        if (error > worst) {
            worst = error;
            worstCode[0] = r, worstCode[1] = g, worstCode[2] = b;
        }
        if (deltaE > worstDeltaE) {
            worstDeltaE = deltaE;
            worstDeltaECode[0] = r, worstDeltaECode[1] = g, worstDeltaECode[2] = b;
        }
        // Codes 1-3 lie inside the first cell of a 65-node table over encoded
        // values, where a pure power curve defeated linear interpolation.
        const auto firstCell = [](int c) { return c >= 1 && c <= 3; };
        if (!firstCell(r) && !firstCell(g) && !firstCell(b)) worstAwayFromBlack = std::max(worstAwayFromBlack, error);
    }
    QString text() const {
        QString line = QStringLiteral("max %1 at (%2,%3,%4); away from codes 1-3 %5; %6 of %7 at or over half a count")
                           .arg(counts(worst)).arg(worstCode[0]).arg(worstCode[1]).arg(worstCode[2])
                           .arg(counts(worstAwayFromBlack)).arg(over).arg(samples);
        if (worstDeltaE > 0)
            line += QStringLiteral("; max delta E*ab %1 at (%2,%3,%4)").arg(worstDeltaE, 0, 'f', 3)
                        .arg(worstDeltaECode[0]).arg(worstDeltaECode[1]).arg(worstDeltaECode[2]);
        return line;
    }
};

// Every sampler over one set of inputs; delta E for exact filtering.
struct Measured {
    Errors by[kSamplers];
    // Over the samplers that must meet the bar.
    double worst() const {
        double w = 0;
        for (int s = 0; s < kRequiredSamplers; ++s) w = std::max(w, by[s].worst);
        return w;
    }
    double worstAnySampler() const {
        double w = 0;
        for (const auto& e : by) w = std::max(w, e.worst);
        return w;
    }
    void print(const QString& what) const {
        for (int s = 0; s < kSamplers; ++s) say(QStringLiteral("measured: %1, %2: %3").arg(what, kSamplerName[s], by[s].text()));
    }
};

std::array<float, 3> shown(const std::array<float, 4>& v) { return {clamp01(v[0]), clamp01(v[1]), clamp01(v[2])}; }
double difference(const std::array<float, 3>& a, const std::array<float, 3>& b) {
    return std::max({std::abs(a[0] - b[0]), std::abs(a[1] - b[1]), std::abs(a[2] - b[2])});
}

// One source colour: the shader model against `want` (Qt's answer, clamped
// as the display shows it) under every sampler.
void addSample(Measured& m, const ColorLut& lut, const std::array<float, 3>& in, const std::array<float, 3>& want,
               const std::array<int, 3>& code, const Lab* lab) {
    for (int s = 0; s < kSamplers; ++s) {
        const auto got = shown(color::sampleLut(lut, in[0], in[1], in[2], kSampling[s]));
        m.by[s].add(difference(got, want), code[0], code[1], code[2], s == 0 && lab ? lab->deltaE(got, want) : 0.0);
    }
}
std::array<float, 3> reference(const QColorTransform& transform, const std::array<float, 3>& in) {
    const QRgbaFloat32 v = transform.map(QRgbaFloat32{in[0], in[1], in[2], 1.0f});
    return {clamp01(v.r), clamp01(v.g), clamp01(v.b)};
}
std::array<float, 3> fromCodes(int r, int g, int b) { return {r / 255.0f, g / 255.0f, b / 255.0f}; }

// Every 8-bit level along the grey axis, the primaries and the secondaries,
// then a million random 8-bit colours.
Measured measure(const ColorLut& lut, const QColorTransform& transform, const Lab* lab = nullptr) {
    Measured m;
    const auto add = [&](int r, int g, int b) {
        const auto in = fromCodes(r, g, b);
        addSample(m, lut, in, reference(transform, in), {r, g, b}, lab);
    };
    const int directions[7][3] = {{1, 1, 1}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {0, 1, 1}, {1, 0, 1}, {1, 1, 0}};
    for (const auto& d : directions)
        for (int v = 0; v < 256; ++v) add(v * d[0], v * d[1], v * d[2]);
    std::mt19937 random(20261016);
    std::uniform_int_distribution<int> code(0, 255);
    for (int i = 0; i < 1000000; ++i) add(code(random), code(random), code(random));
    return m;
}

// Every 8-bit colour with a channel at codes 1-3, 582,939 of them: the region
// a pure power curve made hard, searched exhaustively rather than sampled.
bool inFirstCell(int c) { return c >= 1 && c <= 3; }
Measured firstCellExhaustive(const ColorLut& lut, const QColorTransform& transform, const Lab* lab = nullptr) {
    Measured m;
    for (int r = 0; r < 256; ++r)
        for (int g = 0; g < 256; ++g)
            for (int b = 0; b < 256; ++b)
                if (inFirstCell(r) || inFirstCell(g) || inFirstCell(b)) {
                    const auto in = fromCodes(r, g, b);
                    addSample(m, lut, in, reference(transform, in), {r, g, b}, lab);
                }
    return m;
}

// A million random sRGB colours re-encoded in ProPhoto by Qt, through a
// ProPhoto -> sRGB LUT: they must come back as themselves.
Measured proPhotoRoundTrip(const ColorLut& lut, const Lab* lab = nullptr, int samples = 1000000) {
    const auto toProPhoto = QColorSpace(QColorSpace::SRgb).transformationToColorSpace(QColorSpace::ProPhotoRgb);
    Measured m;
    std::mt19937 random(11);
    std::uniform_int_distribution<int> code(0, 255);
    for (int i = 0; i < samples; ++i) {
        const int r = code(random), g = code(random), b = code(random);
        const auto want = fromCodes(r, g, b);
        const QRgbaFloat32 p = toProPhoto.map(QRgbaFloat32{want[0], want[1], want[2], 1.0f});
        addSample(m, lut, {p.r, p.g, p.b}, want, {r, g, b}, lab);
    }
    return m;
}

// How far outside [0, 1] Qt puts nodes that are on the target's gamut
// boundary in exact arithmetic: the noise kGamutToleranceLinear must absorb.
double boundaryNoise(const QColorSpace& source, const QColorSpace& target) {
    const auto toLinear = source.transformationToColorSpace(target.withTransferFunction(QColorSpace::TransferFunction::Linear));
    double worst = 0;
    for (int b = 0; b < 65; ++b)
        for (int g = 0; g < 65; ++g)
            for (int r = 0; r < 65; ++r) {
                const QRgbaFloat32 v = toLinear.map(QRgbaFloat32{r / 64.0f, g / 64.0f, b / 64.0f, 1.0f});
                for (float c : {v.r, v.g, v.b}) worst = std::max({worst, double(-c), double(c - 1.0f)});
            }
    return worst;
}

int clippedNodes(const ColorLut& lut) {
    int clipped = 0;
    for (std::size_t i = 3; i < lut.rgba.size(); i += 4) clipped += lut.rgba[i] == 0.0f;
    return clipped;
}

void checkCurvedLayout(const ColorLut& lut, const QString& what) {
    check(lut.hasCurves() && lut.curveSize == color::kCurveSize && lut.size == color::kLinearTableSize &&
              lut.shaper.size() == std::size_t(lut.curveSize) * 4 && lut.output.size() == std::size_t(lut.curveSize) * 4 &&
              lut.rgba.size() == std::size_t(lut.size) * lut.size * lut.size * 4,
          QStringLiteral("%1: not the curved layout").arg(what));
}

void testQtFloatMapping() {
    // Both forms rely on map(QRgbaFloat32) not clamping, so the shader can
    // interpolate first and clamp after.
    const auto toSrgb = QColorSpace(QColorSpace::ProPhotoRgb).transformationToColorSpace(QColorSpace::SRgb);
    const QRgbaFloat32 green = toSrgb.map(QRgbaFloat32{0.0f, 1.0f, 0.0f, 1.0f});
    say(QStringLiteral("measured: ProPhoto green in sRGB through Qt's float map: %1 %2 %3")
            .arg(green.r).arg(green.g).arg(green.b));
    check(green.r < -0.1f && green.g > 1.0f, QStringLiteral("QColorTransform::map(QRgbaFloat32) clamps"));
    const auto linear = QColorSpace(QColorSpace::Primaries::ProPhotoRgb, QColorSpace::TransferFunction::Linear)
                            .transformationToColorSpace(QColorSpace(QColorSpace::Primaries::SRgb, QColorSpace::TransferFunction::Linear))
                            .map(QRgbaFloat32{0.0f, 1.0f, 0.0f, 1.0f});
    check(linear.r < -0.1f && linear.g > 1.0f, QStringLiteral("the linear-to-linear map (the curved table) clamps"));
    // A display whose curves are tables (what calibration software writes):
    // whether Qt extends a table past [0, 1] is recorded, not relied upon;
    // gamut is judged in linear light either way.
    QList<uint16_t> table;
    for (int i = 0; i < 1024; ++i) table.append(uint16_t(std::lround(std::pow(i / 1023.0, 2.2) * 65535.0)));
    const QColorSpace tabled = viaIcc(QColorSpace(QColorSpace::Primaries::SRgb, table));
    const QRgbaFloat32 viaTable = QColorSpace(QColorSpace::ProPhotoRgb).transformationToColorSpace(tabled)
                                      .map(QRgbaFloat32{0.0f, 1.0f, 0.0f, 1.0f});
    say(QStringLiteral("measured: the same green to a 1024-entry gamma 2.2 table display: %1 %2 %3")
            .arg(viaTable.r).arg(viaTable.g).arg(viaTable.b));
}

void testIdentity() {
    const QColorSpace display = viaIcc(QColorSpace(QColorSpace::SRgb));
    // The encoded-domain form: every node, every 8-bit ramp, 1M random values.
    QElapsedTimer clock;
    clock.start();
    const auto encoded = color::buildEncodedLut(QColorSpace::SRgb, display);
    say(QStringLiteral("measured: one 65^3 encoded build (sRGB -> sRGB from ICC) took %1 ms").arg(clock.elapsed()));
    check(encoded && encoded->size == color::kEncodedTableSize && !encoded->hasCurves() &&
              encoded->rgba.size() == std::size_t(65 * 65 * 65 * 4),
          QStringLiteral("encoded LUT layout"));
    double worstNode = 0;
    for (int b = 0; b < 65; ++b)
        for (int g = 0; g < 65; ++g)
            for (int r = 0; r < 65; ++r) {
                const float* node = &encoded->rgba[(std::size_t(b * 65 + g) * 65 + r) * 4];
                worstNode = std::max({worstNode, double(std::abs(node[0] - r / 64.0f)),
                                      double(std::abs(node[1] - g / 64.0f)), double(std::abs(node[2] - b / 64.0f))});
                check(node[3] == 1.0f, QStringLiteral("an sRGB node is flagged out of the sRGB gamut"));
            }
    say(QStringLiteral("measured: encoded identity, worst node %1").arg(counts(worstNode)));
    check(worstNode < kBar, QStringLiteral("sRGB -> sRGB nodes are not the identity"));

    // The curved form: the table is the identity in linear light.
    clock.restart();
    const auto curved = color::buildCurvedLut(QColorSpace::SRgb, display);
    say(QStringLiteral("measured: one curved build (sRGB -> sRGB from ICC) took %1 ms").arg(clock.elapsed()));
    checkCurvedLayout(*curved, QStringLiteral("sRGB -> sRGB"));
    const int n = curved->size;
    double worstLinear = 0;
    for (int b = 0; b < n; ++b)
        for (int g = 0; g < n; ++g)
            for (int r = 0; r < n; ++r) {
                const float* node = &curved->rgba[(std::size_t(b * n + g) * n + r) * 4];
                worstLinear = std::max({worstLinear, double(std::abs(node[0] - float(r) / (n - 1))),
                                        double(std::abs(node[1] - float(g) / (n - 1))), double(std::abs(node[2] - float(b) / (n - 1)))});
            }
    say(QStringLiteral("measured: curved identity, worst linear node off by %1").arg(worstLinear, 0, 'g', 3));
    check(worstLinear < 1e-6, QStringLiteral("the curved sRGB -> sRGB table is not the identity"));
    check(color::isNearIdentity(*encoded) && color::isNearIdentity(*curved), QStringLiteral("sRGB -> sRGB is not near identity"));

    for (const auto* lut : {encoded.get(), curved.get()}) {
        const QString form = lut->hasCurves() ? QStringLiteral("curved") : QStringLiteral("encoded");
        double worst[kSamplers] = {};
        const auto add = [&](const float in[3]) {
            for (int s = 0; s < kSamplers; ++s) {
                const auto out = color::sampleLut(*lut, in[0], in[1], in[2], kSampling[s]);
                for (int ch = 0; ch < 3; ++ch) worst[s] = std::max(worst[s], double(std::abs(out[ch] - in[ch])));
            }
        };
        for (int v = 0; v < 256; ++v) {
            const float c = float(v) / 255.0f;
            const float ramps[7][3] = {{c, c, c}, {c, 0, 0}, {0, c, 0}, {0, 0, c}, {0, c, c}, {c, 0, c}, {c, c, 0}};
            for (const auto& in : ramps) add(in);
        }
        std::mt19937 random(7);
        std::uniform_real_distribution<float> unit(0.0f, 1.0f);
        for (int i = 0; i < 1000000; ++i) {
            const float in[3] = {unit(random), unit(random), unit(random)};
            add(in);
        }
        for (int s = 0; s < kSamplers; ++s) {
            say(QStringLiteral("measured: %1 identity through the shader model, ramps and 1M random, %2: %3")
                    .arg(form, kSamplerName[s], counts(worst[s])));
            check(worst[s] < kBar, QStringLiteral("the shader model does not reproduce the %1 identity LUT").arg(form));
        }
    }
}

void testNearIdentity() {
    // The classic sRGB profile stores its curves as 1024-entry tables, which
    // Qt recognises; and a profile with sRGB's red primary rounded 2e-5
    // differently is invisibly close. Both must draw as the identity.
    QList<uint16_t> table;
    for (int i = 0; i < 1024; ++i) table.append(uint16_t(std::lround(srgbToLinear(i / 1023.0) * 65535.0)));
    const QColorSpace tabled = viaIcc(QColorSpace(QColorSpace::Primaries::SRgb, table));
    const QColorSpace rounded = viaIcc(QColorSpace(QPointF(0.3127, 0.3290), QPointF(0.64002, 0.33), QPointF(0.30, 0.60),
                                                   QPointF(0.15, 0.06), QColorSpace::TransferFunction::SRgb));
    const auto tabledLut = color::buildLut(QColorSpace::SRgb, tabled);
    const auto roundedLut = color::buildLut(QColorSpace::SRgb, rounded);
    say(QStringLiteral("measured: table-curve sRGB, sameEncoding %1, near identity %2; red x off by 2e-5, sameEncoding %3, near identity %4")
            .arg(color::sameEncoding(QColorSpace::SRgb, tabled)).arg(color::isNearIdentity(*tabledLut))
            .arg(color::sameEncoding(QColorSpace::SRgb, rounded)).arg(color::isNearIdentity(*roundedLut)));
    check(color::isNearIdentity(*tabledLut) && color::isNearIdentity(*roundedLut),
          QStringLiteral("a profile within rounding of sRGB is not drawn as the identity"));
    // A visible difference must never collapse.
    check(!color::isNearIdentity(*color::buildLut(QColorSpace::SRgb, viaIcc(QColorSpace::DisplayP3))) &&
              !color::isNearIdentity(*color::buildEncodedLut(QColorSpace::SRgb, viaIcc(QColorSpace::DisplayP3))),
          QStringLiteral("Display P3 collapsed to the identity"));
}

void testSwappedPrimaries() {
    // Red and green primaries exchanged: source red must come out as the
    // display's green, which catches a channel or axis swap anywhere.
    const QPointF white(0.3127, 0.3290), red(0.64, 0.33), green(0.30, 0.60), blue(0.15, 0.06);
    const QColorSpace swapped = viaIcc(QColorSpace(white, green, red, blue, QColorSpace::TransferFunction::SRgb));
    const auto near = [](const std::array<float, 4>& got, float r, float g, float b) {
        return std::abs(got[0] - r) < kBar && std::abs(got[1] - g) < kBar && std::abs(got[2] - b) < kBar;
    };
    for (const auto& lut : {color::buildEncodedLut(QColorSpace::SRgb, swapped), color::buildLut(QColorSpace::SRgb, swapped)}) {
        const QString form = lut->hasCurves() ? QStringLiteral("curved") : QStringLiteral("encoded");
        const auto redOut = color::sampleLut(*lut, 1, 0, 0), greenOut = color::sampleLut(*lut, 0, 1, 0);
        say(QStringLiteral("measured: %1, swapped primaries, red -> %2 %3 %4, green -> %5 %6 %7").arg(form)
                .arg(redOut[0]).arg(redOut[1]).arg(redOut[2]).arg(greenOut[0]).arg(greenOut[1]).arg(greenOut[2]));
        check(near(redOut, 0, 1, 0), QStringLiteral("%1, swapped primaries: pure red does not land in G").arg(form));
        check(near(greenOut, 1, 0, 0), QStringLiteral("%1, swapped primaries: pure green does not land in R").arg(form));
        check(near(color::sampleLut(*lut, 0, 0, 1), 0, 0, 1), QStringLiteral("%1, swapped primaries: blue moved").arg(form));
        check(near(color::sampleLut(*lut, 1, 1, 1), 1, 1, 1), QStringLiteral("%1, swapped primaries: white moved").arg(form));
        check(near(color::sampleLut(*lut, 0.75f, 0.25f, 0.5f), 0.25f, 0.75f, 0.5f),
              QStringLiteral("%1, swapped primaries: a mixed colour is not swapped").arg(form));
    }
}

void testGamma26() {
    const QColorSpace gamma26 = viaIcc(QColorSpace(QColorSpace::Primaries::SRgb, 2.6f));
    const auto lut = color::buildLut(QColorSpace::SRgb, gamma26);
    checkCurvedLayout(*lut, QStringLiteral("sRGB -> gamma 2.6"));
    const double expected = std::pow(srgbToLinear(0.5), 1.0 / 2.6);
    const auto grey = color::sampleLut(*lut, 0.5f, 0.5f, 0.5f);
    say(QStringLiteral("measured: gamma 2.6 display, sRGB 0.5 -> %1 (analytic %2, %3 counts)")
            .arg(grey[0], 0, 'f', 5).arg(expected, 0, 'f', 5).arg(std::lround(grey[0] * 255.0)));
    for (int ch = 0; ch < 3; ++ch)
        check(std::abs(grey[ch] - expected) < kBar && std::lround(grey[ch] * 255.0) == 141,
              QStringLiteral("gamma 2.6: sRGB 0.5 does not give 0.5527 (141 counts)"));
    const auto transform = QColorSpace(QColorSpace::SRgb).transformationToColorSpace(gamma26);
    const Lab lab(gamma26);
    const Measured m = measure(*lut, transform, &lab);
    const Measured firstCell = firstCellExhaustive(*lut, transform, &lab);
    m.print(QStringLiteral("sRGB -> gamma 2.6"));
    firstCell.print(QStringLiteral("sRGB -> gamma 2.6, every colour with a channel at codes 1-3"));
    // The encoded table missed by 6.7 counts here; the curves must not.
    check(m.worst() < kBar && firstCell.worst() < kBar, QStringLiteral("gamma 2.6: LUT error is visible in 8 bits"));
}

void testWideGamutTargets() {
    struct Case {
        const char* name;
        QColorSpace display;
    } cases[] = {{"Display P3", viaIcc(QColorSpace::DisplayP3)},
                 {"Adobe RGB", viaIcc(QColorSpace::AdobeRgb)},
                 {"HP Z31x replica", hpZ31xReplica()}};
    for (const auto& item : cases) {
        QElapsedTimer clock;
        clock.start();
        const auto lut = color::buildLut(QColorSpace::SRgb, item.display);
        const qint64 buildMs = clock.elapsed();
        checkCurvedLayout(*lut, QString::fromLatin1(item.name));
        const double noise = boundaryNoise(QColorSpace::SRgb, item.display);
        say(QStringLiteral("measured: sRGB -> %1 built in %2 ms; %3 table nodes clipped; boundary nodes at most %4 outside [0, 1]")
                .arg(item.name).arg(buildMs).arg(clippedNodes(*lut)).arg(noise, 0, 'g', 3));
        const auto transform = QColorSpace(QColorSpace::SRgb).transformationToColorSpace(item.display);
        const Lab lab(item.display);
        const Measured m = measure(*lut, transform, &lab);
        const Measured firstCell = firstCellExhaustive(*lut, transform, &lab);
        m.print(QStringLiteral("sRGB -> %1").arg(item.name));
        firstCell.print(QStringLiteral("sRGB -> %1, every colour with a channel at codes 1-3").arg(item.name));
        check(m.worst() < kBar && firstCell.worst() < kBar, QStringLiteral("%1: LUT error is visible in 8 bits").arg(item.name));
        if (QString::fromLatin1(item.name) != QStringLiteral("HP Z31x replica")) {
            // sRGB lies inside both gamuts, its red and blue exactly on Adobe
            // RGB's boundary: no node may be flagged.
            check(clippedNodes(*lut) == 0 && noise < color::kGamutToleranceLinear,
                  QStringLiteral("%1: sRGB nodes flagged out of gamut").arg(item.name));
        } else {
            // The colour the encoded table missed by 7.2 counts on the real
            // display, through every sampler.
            const auto want = reference(transform, fromCodes(255, 29, 0));
            for (int s = 0; s < kSamplers; ++s) {
                const auto got = shown(color::sampleLut(*lut, 1.0f, 29 / 255.0f, 0.0f, kSampling[s]));
                say(QStringLiteral("measured: HP Z31x replica, (255,29,0), %1: off by %2").arg(kSamplerName[s], counts(difference(got, want))));
                check(difference(got, want) < kBar, QStringLiteral("HP Z31x replica: (255,29,0) is off"));
            }
            check(clippedNodes(*lut) > 0, QStringLiteral("HP Z31x replica: sRGB red is not flagged outside its gamut"));
        }
    }
}

void testProPhotoSource() {
    const QColorSpace prophoto(QColorSpace::ProPhotoRgb);
    QElapsedTimer clock;
    clock.start();
    const auto lut = color::buildLut(prophoto, QColorSpace::SRgb);
    say(QStringLiteral("measured: ProPhoto -> sRGB built in %1 ms").arg(clock.elapsed()));
    checkCurvedLayout(*lut, QStringLiteral("ProPhoto -> sRGB"));
    const auto green = color::sampleLut(*lut, 0, 1, 0);
    check(green[3] == 0.0f, QStringLiteral("ProPhoto green is not flagged outside sRGB"));
    const auto transform = prophoto.transformationToColorSpace(QColorSpace::SRgb);
    const QRgbaFloat32 greyWant = transform.map(QRgbaFloat32{0.5f, 0.5f, 0.5f, 1.0f});
    const auto grey = color::sampleLut(*lut, 0.5f, 0.5f, 0.5f);
    check(grey[3] == 1.0f && std::abs(grey[0] - greyWant.r) < kBar && std::abs(grey[0] - grey[1]) < 1e-3f &&
              std::abs(grey[1] - grey[2]) < 1e-3f,
          QStringLiteral("ProPhoto grey is not a neutral sRGB grey (relative colorimetric)"));
    say(QStringLiteral("measured: ProPhoto -> sRGB: %1 of %2 table nodes outside sRGB; grey 0.5 -> %3")
            .arg(clippedNodes(*lut)).arg(lut->size * lut->size * lut->size).arg(grey[0], 0, 'f', 5));
    check(clippedNodes(*lut) > 0 && clippedNodes(*lut) < lut->size * lut->size * lut->size,
          QStringLiteral("ProPhoto -> sRGB gamut flags are all or nothing"));
    // sRGB colours carried in ProPhoto must come back as themselves: the
    // encoded table missed by 14.5 counts where an sRGB channel crosses zero
    // inside a ProPhoto cell.
    const Lab lab(QColorSpace::SRgb);
    const Measured round = proPhotoRoundTrip(*lut, &lab);
    round.print(QStringLiteral("sRGB colours carried in ProPhoto back to sRGB"));
    check(round.worst() < kBar, QStringLiteral("ProPhoto -> sRGB: sRGB colours do not come back"));
    const auto toProPhoto = QColorSpace(QColorSpace::SRgb).transformationToColorSpace(prophoto);
    const QRgbaFloat32 skin = toProPhoto.map(QRgbaFloat32{0.8f, 0.6f, 0.5f, 1.0f});
    check(color::sampleLut(*lut, skin.r, skin.g, skin.b)[3] == 1.0f, QStringLiteral("an sRGB skin tone is flagged clipped"));
}

void testLutBasedDisplay() {
    // No 3x3 to factor out: the encoded-domain table, which samples Qt's own
    // CLUT evaluation and inherits its limits near black.
    const QColorSpace display = QColorSpace::fromIccProfile(lutDisplayProfile());
    check(display.isValid() && display.isValidTarget() &&
              display.transformModel() == QColorSpace::TransformModel::ElementListProcessing,
          QStringLiteral("the synthetic LUT-based display is not a valid A2B/B2A target"));
    check(!color::curvesApply(QColorSpace::SRgb, display), QStringLiteral("curves offered for a LUT-based display"));
    const auto lut = color::buildLut(QColorSpace::SRgb, display);
    check(!lut->hasCurves() && lut->size == color::kEncodedTableSize, QStringLiteral("a LUT-based display did not get the encoded table"));
    // Three yardsticks over the same colours: the LUT against Qt's evaluation
    // of the profile (what the encoded table samples), Qt's evaluation
    // against the analytic display the profile describes (Rec.2020
    // primaries, gamma 2.2), and the LUT against that analytic display.
    const auto viaQt = QColorSpace(QColorSpace::SRgb).transformationToColorSpace(display);
    const auto analytic = QColorSpace(QColorSpace::SRgb).transformationToColorSpace(
        QColorSpace(QColorSpace::Primaries::Bt2020, QColorSpace::TransferFunction::Gamma, 2.2f));
    Errors lutVsQt, qtVsAnalytic, lutVsAnalytic;
    const auto add = [&](int r, int g, int b) {
        const auto in = fromCodes(r, g, b);
        const auto got = shown(color::sampleLut(*lut, in[0], in[1], in[2]));
        const auto qt = reference(viaQt, in), ideal = reference(analytic, in);
        lutVsQt.add(difference(got, qt), r, g, b);
        qtVsAnalytic.add(difference(qt, ideal), r, g, b);
        lutVsAnalytic.add(difference(got, ideal), r, g, b);
    };
    const int directions[7][3] = {{1, 1, 1}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {0, 1, 1}, {1, 0, 1}, {1, 1, 0}};
    for (const auto& d : directions)
        for (int v = 0; v < 256; ++v) add(v * d[0], v * d[1], v * d[2]);
    std::mt19937 random(20261016);
    std::uniform_int_distribution<int> code(0, 255);
    for (int i = 0; i < 1000000; ++i) add(code(random), code(random), code(random));
    say(QStringLiteral("measured: LUT-based display, encoded table against Qt's evaluation: ") + lutVsQt.text());
    say(QStringLiteral("measured: LUT-based display, Qt's evaluation against the analytic display: ") + qtVsAnalytic.text());
    say(QStringLiteral("measured: LUT-based display, encoded table against the analytic display: ") + lutVsAnalytic.text());
    // The table may not be worse than the profile's own evaluation by more
    // than half a count anywhere it was measured. Against Qt it keeps the
    // encoded form's limit near black (codes 1-3), pinned so it cannot grow.
    check(lutVsAnalytic.worst < qtVsAnalytic.worst + kBar, QStringLiteral("LUT-based display: the encoded table adds error"));
    check(lutVsQt.worst < 3.5 / 255.0 && lutVsQt.worstAwayFromBlack < 2.0 / 255.0,
          QStringLiteral("LUT-based display: the encoded table's error against Qt grew"));
    const auto mid = color::sampleLut(*lut, 0.5f, 0.5f, 0.5f);
    check(difference(shown(mid), reference(viaQt, {0.5f, 0.5f, 0.5f})) < kBar, QStringLiteral("LUT-based display: mid grey is off"));
}

void testUnusableProfiles() {
    const QByteArray p3 = iccOf(QColorSpace::DisplayP3);
    color::DisplayInfo display;
    display.screenId = QStringLiteral("\\\\.\\DISPLAY1");
    display.monitorName = QStringLiteral("Test Monitor");
    display.profilePath = QStringLiteral("C:/profiles/test.icc");
    const auto expectFallback = [&](const QByteArray& icc, const QString& reason, const QString& what) {
        display.icc = icc;
        const color::DisplayTarget target = color::resolveTarget(QStringLiteral("automatic"), display, {});
        say(QStringLiteral("measured: %1 -> \"%2\" / \"%3\"").arg(what, target.displayName, target.status));
        check(target.space == QColorSpace(QColorSpace::SRgb) && target.hash == color::srgbTarget({}).hash,
              QStringLiteral("%1 does not fall back to sRGB").arg(what));
        check(target.status.contains(reason) && target.status.contains(QStringLiteral("Showing sRGB")) &&
                  target.status.contains(QStringLiteral("test.icc")) && target.displayName.contains(QStringLiteral("sRGB (fallback)")),
              QStringLiteral("%1 has no visible warning").arg(what));
    };
    expectFallback(p3.left(200), QStringLiteral("truncated"), QStringLiteral("truncated profile"));
    expectFallback(p3.left(100), QStringLiteral("truncated"), QStringLiteral("profile shorter than its header"));
    QByteArray garbage = p3;
    for (int i = 128; i < garbage.size(); ++i) garbage[i] = char(0xA5);
    expectFallback(garbage, QStringLiteral("Qt cannot read"), QStringLiteral("corrupt tag data"));

    // The synthesised profiles must be what they claim, or the fallback
    // would be tested only through "unreadable" (AGENTS.md trap 16).
    const QByteArray cmyk = cmykProfile();
    const QColorSpace cmykSpace = QColorSpace::fromIccProfile(cmyk);
    check(cmykSpace.isValid() && cmykSpace.colorModel() == QColorSpace::ColorModel::Cmyk,
          QStringLiteral("the synthetic CMYK profile does not parse as CMYK"));
    expectFallback(cmyk, QStringLiteral("CMYK"), QStringLiteral("CMYK profile"));
    const QByteArray a2b = a2bOnlyProfile();
    const QColorSpace a2bSpace = QColorSpace::fromIccProfile(a2b);
    check(a2bSpace.isValid() && a2bSpace.colorModel() == QColorSpace::ColorModel::Rgb && !a2bSpace.isValidTarget() &&
              a2bSpace.transformModel() == QColorSpace::TransformModel::ElementListProcessing,
          QStringLiteral("the synthetic A2B-only profile is not a valid source-only RGB profile"));
    expectFallback(a2b, QStringLiteral("A2B-only"), QStringLiteral("A2B-only profile"));
    const QColorSpace grey(QPointF(0.3127, 0.3290), QColorSpace::TransferFunction::SRgb);
    const QByteArray greyIcc = iccOf(grey);
    check(QColorSpace::fromIccProfile(greyIcc).colorModel() == QColorSpace::ColorModel::Gray,
          QStringLiteral("the grey profile does not parse as grey"));
    expectFallback(greyIcc, QStringLiteral("greyscale"), QStringLiteral("greyscale profile"));

    // A usable one, and the absent and unreadable cases.
    display.icc = p3;
    const auto usable = color::resolveTarget(QStringLiteral("automatic"), display, {});
    check(usable.status.isEmpty() && usable.displayName == QStringLiteral("Test Monitor - test.icc") && usable.icc == p3,
          QStringLiteral("a usable display profile is not the target"));
    color::DisplayInfo none;
    none.monitorName = QStringLiteral("Bare");
    const auto bare = color::resolveTarget(QStringLiteral("automatic"), none, {});
    check(bare.space == QColorSpace(QColorSpace::SRgb) && bare.status.isEmpty() &&
              bare.displayName == QStringLiteral("Bare - sRGB (no display profile)"),
          QStringLiteral("a display without a profile is not plain sRGB"));
    color::DisplayInfo missing = display;
    missing.icc.clear();
    missing.error = QStringLiteral("Windows names the display profile \"test.icc\", but the file does not exist");
    const auto unreadable = color::resolveTarget(QStringLiteral("automatic"), missing, {});
    check(unreadable.space == QColorSpace(QColorSpace::SRgb) && unreadable.status.contains(QStringLiteral("does not exist")),
          QStringLiteral("a missing profile file has no warning"));
}

// --- simulated monitors driving the real pipeline.
class FakeMonitors final : public color::ProfileSource {
public:
    std::map<QString, color::DisplayInfo> monitors;
    int queries = 0;
    color::DisplayInfo query(const QString& screenId) override {
        ++queries;
        const auto it = monitors.find(screenId);
        if (it != monitors.end()) return it->second;
        color::DisplayInfo none;
        none.screenId = screenId;
        return none;
    }
};
color::DisplayInfo monitor(const QString& id, const QString& name, const QString& file, const QByteArray& icc) {
    color::DisplayInfo info;
    info.screenId = id;
    info.monitorName = name;
    info.profilePath = QStringLiteral("C:/Windows/System32/spool/drivers/color/") + file;
    info.icc = icc;
    info.profileSize = icc.size();
    info.profileModifiedMs = 1;
    info.lookup = QStringLiteral("simulated");
    return info;
}

class TestPipeline final : public ColorPipeline {
public:
    TestPipeline() : ColorPipeline(nullptr) {}
};

bool waitFor(const std::function<bool()>& done, int timeoutMs) {
    QElapsedTimer clock;
    clock.start();
    while (!done()) {
        if (clock.elapsed() > timeoutMs) return false;
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        QThread::msleep(1);
    }
    return true;
}

// Worst error of a LUT against Qt over a coarse 8-bit grid.
double coarseError(const ColorLut& lut, const QColorSpace& from, const QColorSpace& to) {
    const auto transform = from.transformationToColorSpace(to);
    double worst = 0;
    for (int r = 0; r < 256; r += 17)
        for (int g = 0; g < 256; g += 17)
            for (int b = 0; b < 256; b += 17) {
                const auto in = fromCodes(r, g, b);
                worst = std::max(worst, difference(shown(color::sampleLut(lut, in[0], in[1], in[2])), reference(transform, in)));
            }
    return worst;
}

void testPipeline(const QString& scratch) {
    const QString one = QStringLiteral("\\\\.\\DISPLAY1"), two = QStringLiteral("\\\\.\\DISPLAY2"),
                  three = QStringLiteral("\\\\.\\DISPLAY3");
    const QByteArray p3 = iccOf(QColorSpace::DisplayP3), adobe = iccOf(QColorSpace::AdobeRgb);
    const QByteArray gamma26 = iccOf(QColorSpace(QColorSpace::Primaries::SRgb, 2.6f));
    const QColorSpace srgb(QColorSpace::SRgb), prophoto(QColorSpace::ProPhotoRgb);
    auto fake = std::make_shared<FakeMonitors>();
    fake->monitors[one] = monitor(one, QStringLiteral("Studio P3"), QStringLiteral("studio-p3.icc"), p3);
    fake->monitors[two] = monitor(two, QStringLiteral("Proof Adobe"), QStringLiteral("proof-adobe.icc"), adobe);
    fake->monitors[three] = monitor(three, QStringLiteral("Calibrated LUT"), QStringLiteral("lut-display.icc"), lutDisplayProfile());

    TestPipeline pipeline;
    int changes = 0;
    QObject::connect(&pipeline, &ColorPipeline::changed, [&] { ++changes; });
    check(pipeline.mode() == QStringLiteral("automatic"), QStringLiteral("the default mode is not automatic"));
    pipeline.setProfileSourceForTesting(fake);
    const auto lutKey = [&](const QColorSpace& space) { return pipeline.lut(space)->key; };

    // Monitor one: P3. Nothing is built yet, so the identity is served.
    int before = changes;
    pipeline.setScreenForTesting(one);
    check(changes > before, QStringLiteral("moving to a monitor emits no changed()"));
    check(pipeline.displayName() == QStringLiteral("Studio P3 - studio-p3.icc") && pipeline.status().isEmpty(),
          QStringLiteral("monitor one: %1 / %2").arg(pipeline.displayName(), pipeline.status()));
    check(pipeline.targetColorSpace().iccProfile() == p3, QStringLiteral("monitor one's profile is not the target"));
    check(pipeline.lut(srgb)->isIdentity(), QStringLiteral("a LUT appeared before its build was delivered"));
    before = changes;
    check(waitFor([&] { return !pipeline.lut(srgb)->isIdentity(); }, 20000), QStringLiteral("the P3 LUT never landed"));
    check(changes > before, QStringLiteral("a landed LUT emits no changed()"));
    const quint64 keyP3 = lutKey(srgb);
    check(pipeline.lut(srgb)->hasCurves(), QStringLiteral("a matrix/TRC display was not given curves"));
    check(coarseError(*pipeline.lut(srgb), srgb, viaIcc(QColorSpace::DisplayP3)) < kBar, QStringLiteral("the served LUT is not sRGB -> P3"));

    // Monitor two: Adobe RGB. The P3 LUT is served until the new one lands.
    before = changes;
    pipeline.setScreenForTesting(two);
    check(changes == before + 1 && pipeline.displayName() == QStringLiteral("Proof Adobe - proof-adobe.icc"),
          QStringLiteral("moving to monitor two: %1").arg(pipeline.displayName()));
    check(lutKey(srgb) == keyP3, QStringLiteral("the old LUT was not served while the new one builds"));
    check(waitFor([&] { return lutKey(srgb) != keyP3; }, 20000), QStringLiteral("the Adobe RGB LUT never landed"));
    const quint64 keyAdobe = lutKey(srgb);
    check(coarseError(*pipeline.lut(srgb), srgb, viaIcc(QColorSpace::AdobeRgb)) < kBar, QStringLiteral("the served LUT is not sRGB -> Adobe RGB"));

    // Monitor three: a LUT-based profile gets the encoded table.
    pipeline.setScreenForTesting(three);
    check(waitFor([&] { return lutKey(srgb) != keyAdobe; }, 20000), QStringLiteral("the LUT-based display's LUT never landed"));
    check(!pipeline.lut(srgb)->hasCurves() && pipeline.lut(srgb)->size == color::kEncodedTableSize,
          QStringLiteral("a LUT-based display was given curves"));

    // Back to monitor one: from the cache, at once.
    pipeline.setScreenForTesting(one);
    check(lutKey(srgb) == keyP3, QStringLiteral("returning to monitor one rebuilt its LUT"));

    // Monitor one is recalibrated in place: same file, new bytes.
    fake->monitors[one].icc = gamma26;
    fake->monitors[one].profileModifiedMs = 2;
    before = changes;
    pipeline.reload();
    check(changes == before + 1, QStringLiteral("a changed profile emits no changed()"));
    check(lutKey(srgb) == keyP3, QStringLiteral("the old LUT was not served after a profile change"));
    check(waitFor([&] { return lutKey(srgb) != keyP3; }, 20000), QStringLiteral("the recalibrated LUT never landed"));
    const auto grey = color::sampleLut(*pipeline.lut(srgb), 0.5f, 0.5f, 0.5f);
    check(std::lround(grey[1] * 255.0) == 141, QStringLiteral("the recalibrated LUT is not gamma 2.6"));

    // ...and back, with no reload(): only the 3 s poll can notice.
    fake->monitors[one].icc = p3;
    fake->monitors[one].profileModifiedMs = 3;
    QElapsedTimer clock;
    clock.start();
    check(waitFor([&] { return lutKey(srgb) == keyP3; }, 6000), QStringLiteral("the poll did not pick up a profile change"));
    say(QStringLiteral("measured: the poll noticed a profile change after %1 ms").arg(clock.elapsed()));

    // Auto Color Management: Windows manages the canvas as sRGB.
    fake->monitors[one].mode = color::DisplayMode::AutoColorManaged;
    before = changes;
    pipeline.reload();
    check(changes == before + 1 && pipeline.status().contains(QStringLiteral("Windows Auto Color Management is on")) &&
              pipeline.status().contains(QStringLiteral("Use legacy display ICC color management")) &&
              pipeline.displayName() == QStringLiteral("Studio P3 - sRGB (Windows Auto Color Management)"),
          QStringLiteral("ACM: %1 / %2").arg(pipeline.displayName(), pipeline.status()));
    check(pipeline.targetColorSpace() == srgb && pipeline.lut(srgb)->isIdentity(), QStringLiteral("ACM does not target sRGB"));
    check(waitFor([&] { return !pipeline.lut(prophoto)->isIdentity(); }, 20000), QStringLiteral("ProPhoto -> sRGB never landed"));
    const quint64 keyProPhoto = lutKey(prophoto);
    check(color::sampleLut(*pipeline.lut(prophoto), 0, 1, 0)[3] == 0.0f, QStringLiteral("ACM: ProPhoto green not flagged"));

    fake->monitors[one].mode = color::DisplayMode::Hdr;
    pipeline.reload();
    check(pipeline.status().contains(QStringLiteral("HDR")) && pipeline.lut(srgb)->isIdentity() && lutKey(prophoto) == keyProPhoto,
          QStringLiteral("HDR: %1").arg(pipeline.status()));

    // An unusable profile on an SDR monitor: sRGB with a warning.
    fake->monitors[one].mode = color::DisplayMode::Sdr;
    fake->monitors[one].icc = p3.left(300);
    pipeline.reload();
    check(pipeline.status().contains(QStringLiteral("truncated")) && pipeline.lut(srgb)->isIdentity() &&
              pipeline.displayName() == QStringLiteral("Studio P3 - sRGB (fallback)"),
          QStringLiteral("truncated: %1 / %2").arg(pipeline.displayName(), pipeline.status()));

    // Overrides: assume sRGB, then a custom file.
    before = changes;
    pipeline.setMode(QStringLiteral("srgb"));
    check(changes > before && pipeline.displayName() == QStringLiteral("sRGB (assumed)") && pipeline.status().isEmpty() &&
              pipeline.lut(srgb)->isIdentity() && lutKey(prophoto) == keyProPhoto,
          QStringLiteral("srgb mode: %1 / %2").arg(pipeline.displayName(), pipeline.status()));
    const QString customPath = scratch + QStringLiteral("/custom-p3.icc");
    QFile customFile(customPath);
    check(customFile.open(QIODevice::WriteOnly | QIODevice::Truncate) && customFile.write(p3) == p3.size(), QStringLiteral("cannot write the custom profile"));
    customFile.close();
    pipeline.setCustomProfilePath(customPath);
    pipeline.setMode(QStringLiteral("custom"));
    check(pipeline.displayName() == QStringLiteral("Custom - custom-p3.icc") && pipeline.status().isEmpty() && lutKey(srgb) == keyP3,
          QStringLiteral("custom mode: %1 / %2").arg(pipeline.displayName(), pipeline.status()));
    const QString truncatedPath = scratch + QStringLiteral("/custom-truncated.icc");
    QFile truncatedFile(truncatedPath);
    check(truncatedFile.open(QIODevice::WriteOnly | QIODevice::Truncate) && truncatedFile.write(adobe.left(150)) == 150, QStringLiteral("cannot write the truncated profile"));
    truncatedFile.close();
    pipeline.setCustomProfilePath(truncatedPath);
    check(pipeline.status().contains(QStringLiteral("custom display profile")) && pipeline.status().contains(QStringLiteral("truncated")) &&
              pipeline.lut(srgb)->isIdentity(),
          QStringLiteral("unusable custom profile: %1").arg(pipeline.status()));
    pipeline.setCustomProfilePath(scratch + QStringLiteral("/absent.icc"));
    check(pipeline.status().contains(QStringLiteral("does not exist")), QStringLiteral("absent custom profile: %1").arg(pipeline.status()));

    // Back to automatic on monitor two: its LUT is still cached.
    pipeline.setMode(QStringLiteral("automatic"));
    pipeline.setScreenForTesting(two);
    check(lutKey(srgb) == keyAdobe, QStringLiteral("monitor two's LUT was not reused"));

    // The test hook still overrides everything.
    auto forced = std::make_shared<ColorLut>();
    forced->size = 2;
    forced->rgba.assign(2 * 2 * 2 * 4, 0.5f);
    forced->key = color::nextLutKey();
    pipeline.setLutOverrideForTesting(forced);
    check(pipeline.lut(prophoto) == forced && pipeline.lut(srgb) == forced, QStringLiteral("the test override is ignored"));
    pipeline.setLutOverrideForTesting(nullptr);
    check(lutKey(srgb) == keyAdobe, QStringLiteral("clearing the override did not restore the LUT"));
    say(QStringLiteral("measured: %1 changed() signals, %2 profile queries over the simulation").arg(changes).arg(fake->queries));
}

void testWindows() {
    // One pipeline per window, owned by it, also when the render thread asks
    // first (from updatePaintNode, with the GUI thread blocked).
    QQuickWindow window;
    ColorPipeline* pipeline = ColorPipeline::forWindow(&window);
    check(pipeline && pipeline == ColorPipeline::forWindow(&window) && pipeline->parent() == &window,
          QStringLiteral("forWindow does not give one pipeline owned by the window"));
    QQuickWindow other;
    ColorPipeline* fromRenderThread = nullptr;
    std::unique_ptr<QThread> render(QThread::create([&] { fromRenderThread = ColorPipeline::forWindow(&other); }));
    render->start();
    render->wait();
    check(fromRenderThread && fromRenderThread->thread() == other.thread(),
          QStringLiteral("a pipeline made on another thread does not move to the window's"));
    check(waitFor([&] { return fromRenderThread->parent() == &other; }, 2000),
          QStringLiteral("a pipeline made on another thread is never owned by its window"));
    check(ColorPipeline::forWindow(&other) == fromRenderThread, QStringLiteral("the render-thread pipeline is not reused"));
}

// The measurements kLinearTableSize and kCurveSize were chosen from: the
// worst error per sampler for the cases that defeated the encoded table, for
// table sizes at the default curve size and curve sizes at the default table
// size, with the encoded table as the "before" row; then how often the
// interpolated gamut flag (alpha < 0.5) disagrees with Qt.
int sweep() {
    struct Case {
        QString name;
        QColorSpace source, display;
        bool viaProPhoto;
    };
    const QColorSpace srgb(QColorSpace::SRgb);
    const std::vector<Case> cases = {
        {QStringLiteral("sRGB -> Adobe RGB"), srgb, viaIcc(QColorSpace::AdobeRgb), false},
        {QStringLiteral("sRGB -> gamma 2.6"), srgb, viaIcc(QColorSpace(QColorSpace::Primaries::SRgb, 2.6f)), false},
        {QStringLiteral("sRGB -> HP Z31x replica"), srgb, hpZ31xReplica(), false},
        {QStringLiteral("sRGB -> Display P3"), srgb, viaIcc(QColorSpace::DisplayP3), false},
        {QStringLiteral("sRGB via ProPhoto -> sRGB"), QColorSpace(QColorSpace::ProPhotoRgb), srgb, true},
    };
    struct Config {
        bool curves;
        int table, curve;
    };
    std::vector<Config> configs = {{false, 65, 0}};
    for (int n : {9, 17, 33, 65, 129}) configs.push_back({true, n, 4096});
    for (int m : {256, 1024}) configs.push_back({true, 65, m});
    for (const Case& item : cases) {
        // Inputs and Qt's answers, once per case.
        std::vector<std::array<float, 3>> in, want;
        if (!item.viaProPhoto) {
            const auto transform = item.source.transformationToColorSpace(item.display);
            const auto add = [&](int r, int g, int b) {
                in.push_back(fromCodes(r, g, b));
                want.push_back(reference(transform, in.back()));
            };
            const int directions[7][3] = {{1, 1, 1}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {0, 1, 1}, {1, 0, 1}, {1, 1, 0}};
            for (const auto& d : directions)
                for (int v = 0; v < 256; ++v) add(v * d[0], v * d[1], v * d[2]);
            std::mt19937 random(20261016);
            std::uniform_int_distribution<int> code(0, 255);
            for (int i = 0; i < 200000; ++i) add(code(random), code(random), code(random));
            for (int r = 0; r < 256; ++r)
                for (int g = 0; g < 256; ++g)
                    for (int b = 0; b < 256; ++b)
                        if (inFirstCell(r) || inFirstCell(g) || inFirstCell(b)) add(r, g, b);
        } else {
            const auto toProPhoto = srgb.transformationToColorSpace(item.source);
            std::mt19937 random(11);
            std::uniform_int_distribution<int> code(0, 255);
            for (int i = 0; i < 300000; ++i) {
                want.push_back(fromCodes(code(random), code(random), code(random)));
                const QRgbaFloat32 p = toProPhoto.map(QRgbaFloat32{want.back()[0], want.back()[1], want.back()[2], 1.0f});
                in.push_back({p.r, p.g, p.b});
            }
        }
        for (const Config& config : configs) {
            const auto lut = config.curves ? color::buildCurvedLut(item.source, item.display, config.table, config.curve)
                                           : color::buildEncodedLut(item.source, item.display, config.table);
            double worst[kSamplers] = {};
            for (std::size_t i = 0; i < in.size(); ++i)
                for (int s = 0; s < kSamplers; ++s)
                    worst[s] = std::max(worst[s], difference(shown(color::sampleLut(*lut, in[i][0], in[i][1], in[i][2], kSampling[s])), want[i]));
            say(QStringLiteral("sweep: %1 | %2 | worst over %3 inputs: exact %4; recommended %5; table on rounded 8-bit %6, "
                               "truncated 8-bit %7, halves %8; curves in halves %9")
                    .arg(item.name, config.curves ? QStringLiteral("table %1, curves %2").arg(config.table).arg(config.curve)
                                                  : QStringLiteral("encoded table %1 (before)").arg(config.table))
                    .arg(in.size()).arg(counts(worst[0]), counts(worst[1]), counts(worst[2]), counts(worst[3]))
                    .arg(counts(worst[4]), counts(worst[5])));
        }
    }
    // The gamut flag: ProPhoto colours uniform in the encoded cube.
    const QColorSpace prophoto(QColorSpace::ProPhotoRgb);
    const auto toLinear = prophoto.transformationToColorSpace(srgb.withTransferFunction(QColorSpace::TransferFunction::Linear));
    std::vector<std::array<float, 3>> colours;
    std::vector<bool> outside;
    std::mt19937 random(5);
    std::uniform_real_distribution<float> unit(0.0f, 1.0f);
    for (int i = 0; i < 300000; ++i) {
        colours.push_back({unit(random), unit(random), unit(random)});
        const QRgbaFloat32 v = toLinear.map(QRgbaFloat32{colours.back()[0], colours.back()[1], colours.back()[2], 1.0f});
        const auto in = [](float c) { return c >= -color::kGamutToleranceLinear && c <= 1.0f + color::kGamutToleranceLinear; };
        outside.push_back(!(in(v.r) && in(v.g) && in(v.b)));
    }
    for (const Config& config : configs) {
        if (config.curves && config.curve != 4096) continue;
        const auto lut = config.curves ? color::buildCurvedLut(prophoto, srgb, config.table, config.curve)
                                       : color::buildEncodedLut(prophoto, srgb, config.table);
        int wrong = 0;
        for (std::size_t i = 0; i < colours.size(); ++i)
            wrong += (color::sampleLut(*lut, colours[i][0], colours[i][1], colours[i][2])[3] < 0.5f) != outside[i];
        say(QStringLiteral("sweep: gamut flag, ProPhoto -> sRGB | %1 | %2 % of 300000 colours misflagged")
                .arg(config.curves ? QStringLiteral("table %1").arg(config.table) : QStringLiteral("encoded table %1").arg(config.table))
                .arg(100.0 * wrong / double(colours.size()), 0, 'f', 3));
    }
    return 0;
}

int probe() {
    // Read-only: what each Windows query says, what the pipeline would do.
    const auto source = color::systemProfileSource();
    const QStringList ids = color::systemScreenIds();
    // A known space first, to read the profile lines below against: Qt
    // 6.11.3 returns sRGB's red primary as its white point (measured), so the
    // fields of primaryPoints() are printed as returned, not trusted.
    const auto srgbPoints = QColorSpace(QColorSpace::SRgb).primaryPoints();
    say(QStringLiteral("reference: Qt's sRGB primaryPoints() white %1,%2 red %3,%4")
            .arg(srgbPoints.whitePoint.x(), 0, 'f', 4).arg(srgbPoints.whitePoint.y(), 0, 'f', 4)
            .arg(srgbPoints.redPoint.x(), 0, 'f', 4).arg(srgbPoints.redPoint.y(), 0, 'f', 4));
    say(QStringLiteral("monitors: %1").arg(ids.join(QStringLiteral(", "))));
    for (const QScreen* screen : QGuiApplication::screens())
        say(QStringLiteral("Qt screen \"%1\" (%2) -> %3").arg(screen->name(), screen->model(), color::screenIdOf(screen)));
    for (const QString& id : ids) {
        say(QStringLiteral("== %1").arg(id));
        for (const QString& line : color::describeSystemLookups(id)) say(QStringLiteral("  ") + line);
        QElapsedTimer clock;
        clock.start();
        const color::DisplayInfo info = source->query(id);
        const qint64 first = clock.nsecsElapsed();
        clock.restart();
        constexpr int kRepeats = 50;
        for (int i = 0; i < kRepeats; ++i) source->query(id);
        const double repeated = double(clock.nsecsElapsed()) / kRepeats;
        say(QStringLiteral("  query: monitor \"%1\", %2, profile \"%3\" (%4 bytes), via %5%6")
                .arg(info.monitorName, color::displayModeName(info.mode), info.profilePath).arg(info.icc.size())
                .arg(info.lookup, info.error.isEmpty() ? QString() : QStringLiteral(", error: ") + info.error));
        say(QStringLiteral("  query cost: first %1 ms, then %2 ms each over %3")
                .arg(first / 1e6, 0, 'f', 2).arg(repeated / 1e6, 0, 'f', 3).arg(kRepeats));
        if (!info.icc.isEmpty()) {
            const color::ProfileCheck checked = color::checkDisplayProfile(info.icc);
            if (checked.problem.isEmpty()) {
                const auto points = checked.space.primaryPoints();
                say(QStringLiteral("  profile: \"%1\", model %2, primaries %3, transfer %4, gamma %5, primaryPoints() as returned: "
                                   "white %6,%7 red %8,%9 green %10,%11 blue %12,%13")
                        .arg(checked.space.description()).arg(int(checked.space.transformModel()))
                        .arg(int(checked.space.primaries())).arg(int(checked.space.transferFunction()))
                        .arg(checked.space.gamma(), 0, 'f', 6)
                        .arg(points.whitePoint.x(), 0, 'f', 6).arg(points.whitePoint.y(), 0, 'f', 6)
                        .arg(points.redPoint.x(), 0, 'f', 6).arg(points.redPoint.y(), 0, 'f', 6)
                        .arg(points.greenPoint.x(), 0, 'f', 6).arg(points.greenPoint.y(), 0, 'f', 6)
                        .arg(points.bluePoint.x(), 0, 'f', 6).arg(points.bluePoint.y(), 0, 'f', 6));
                say(QStringLiteral("  sRGB source is identity on it: %1").arg(color::sameEncoding(QColorSpace::SRgb, checked.space)));
                // The LUT the canvas would get for an sRGB frame, and the old
                // encoded table, measured against Qt as the tests measure.
                const auto transform = QColorSpace(QColorSpace::SRgb).transformationToColorSpace(checked.space);
                const Lab lab(checked.space);
                for (const bool curves : {false, true}) {
                    if (curves && !color::curvesApply(QColorSpace::SRgb, checked.space)) continue;
                    QElapsedTimer build;
                    build.start();
                    const auto lut = curves ? color::buildLut(QColorSpace::SRgb, checked.space)
                                            : color::buildEncodedLut(QColorSpace::SRgb, checked.space);
                    const qint64 buildMs = build.elapsed();
                    const QString form = curves ? QStringLiteral("curves (served)") : QStringLiteral("encoded table (before)");
                    say(QStringLiteral("  sRGB -> this display, %1: built in %2 ms, %3 table nodes clipped, near identity %4")
                            .arg(form).arg(buildMs).arg(clippedNodes(*lut)).arg(color::isNearIdentity(*lut)));
                    const Measured m = measure(*lut, transform, &lab);
                    const Measured firstCell = firstCellExhaustive(*lut, transform, &lab);
                    for (int s = 0; s < kSamplers; ++s) {
                        say(QStringLiteral("    %1: %2").arg(kSamplerName[s], m.by[s].text()));
                        say(QStringLiteral("    %1, every colour with a channel at codes 1-3: %2").arg(kSamplerName[s], firstCell.by[s].text()));
                    }
                    const auto want = reference(transform, fromCodes(255, 29, 0));
                    say(QStringLiteral("    (255,29,0): off by %1").arg(counts(difference(shown(color::sampleLut(*lut, 1.0f, 29 / 255.0f, 0.0f)), want))));
                }
            } else {
                say(QStringLiteral("  profile unusable: ") + checked.problem);
            }
        }
        const color::DisplayTarget target = color::resolveTarget(QStringLiteral("automatic"), info, {});
        say(QStringLiteral("  automatic -> \"%1\"%2").arg(target.displayName,
            target.status.isEmpty() ? QString() : QStringLiteral(", status: ") + target.status));
    }
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    const QByteArray mode = argc > 1 ? QByteArray(argv[1]) : QByteArray();
    const bool probing = mode == "--probe-display";
    // The probe wants the real Windows screens; everything else wants none.
    if (!probing) qputenv("QT_QPA_PLATFORM", "offscreen");
    QGuiApplication application(argc, argv);
    if (probing) return probe();
    try {
        if (mode == "--sweep") return sweep();
        // CTest passes a scratch directory in the build tree.
        const QString scratch = application.arguments().value(1);
        check(!scratch.isEmpty() && QDir().mkpath(scratch), QStringLiteral("pass a scratch directory"));
        testQtFloatMapping();
        testIdentity();
        testNearIdentity();
        testSwappedPrimaries();
        testGamma26();
        testWideGamutTargets();
        testProPhotoSource();
        testLutBasedDisplay();
        testUnusableProfiles();
        testPipeline(scratch);
        testWindows();
    } catch (const std::exception& error) {
        std::fprintf(stderr, "FAILED after %d checks: %s\n", checks, error.what());
        return 1;
    }
    std::printf("colour core: %d checks passed\n", checks);
    return 0;
}
