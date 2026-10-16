// The colour core on the CPU. Every ICC profile is made here, from Qt's own
// colour spaces or byte by byte; the LUT is held to Qt's transform through the
// model of the shader's lookup (ColorLut.hpp); simulated monitors drive the
// real ColorPipeline. No GPU, no shown window, no installed profile is read.
//
// `--probe-display` instead prints what the Windows queries say about this
// machine's monitors. It reads, and changes nothing.
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

// --- ICC profiles Qt cannot write: an A2B-only RGB profile and a CMYK one.
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
// lut16Type: identity matrix and identity curves around a `grid`-point CLUT;
// `node` gives the 16-bit outputs at a grid point (first input slowest).
QByteArray lut16Type(int inputs, int outputs, int grid,
                     const std::function<std::vector<quint16>(const std::vector<double>&)>& node) {
    QByteArray t;
    putSig(t, "mft2");
    putU32(t, 0);
    t.append(char(inputs));
    t.append(char(outputs));
    t.append(char(grid));
    t.append('\0');
    for (int i = 0; i < 9; ++i) putFixed(t, i % 4 == 0 ? 1.0 : 0.0);
    putU16(t, 2);
    putU16(t, 2);
    for (int i = 0; i < inputs; ++i) {
        putU16(t, 0);
        putU16(t, 65535);
    }
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
    for (int i = 0; i < outputs; ++i) {
        putU16(t, 0);
        putU16(t, 65535);
    }
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
quint16 unit16(double v, double scale) { return quint16(std::clamp(std::lround(v * scale), 0l, 65535l)); }

// An RGB display described only device -> PCS: valid as a source, never a target.
QByteArray a2bOnlyProfile() {
    // sRGB's primaries adapted to D50, linear light: any content would do.
    const double primaries[3][3] = {{0.4361, 0.2225, 0.0139}, {0.3851, 0.7169, 0.0971}, {0.1431, 0.0606, 0.7141}};
    return buildIcc("mntr", "RGB ", "XYZ ", {
        {"desc", mlucType(QStringLiteral("A2B-only RGB"))},
        {"cprt", mlucType(QStringLiteral("No copyright, test data"))},
        {"wtpt", xyzType(0.9642, 1.0, 0.8249)},
        {"A2B0", lut16Type(3, 3, 2, [&](const std::vector<double>& rgb) {
             std::vector<quint16> xyz;
             for (int c = 0; c < 3; ++c) {
                 const double v = rgb[0] * primaries[0][c] + rgb[1] * primaries[1][c] + rgb[2] * primaries[2][c];
                 xyz.push_back(unit16(v, 32768.0)); // lut16 PCSXYZ: 1.0 is 0x8000
             }
             return xyz;
         })},
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
        // Codes 1-3 lie inside the first LUT cell, [0, 1/64), where a pure
        // power curve's infinite slope at zero defeats linear interpolation.
        const auto firstCell = [](int c) { return c >= 1 && c <= 3; };
        if (!firstCell(r) && !firstCell(g) && !firstCell(b)) worstAwayFromBlack = std::max(worstAwayFromBlack, error);
    }
    QString text() const {
        QString line = QStringLiteral("max %1 at (%2,%3,%4); away from codes 1-3 %5; %6 of %7 samples at or over half a count")
                           .arg(counts(worst)).arg(worstCode[0]).arg(worstCode[1]).arg(worstCode[2])
                           .arg(counts(worstAwayFromBlack)).arg(over).arg(samples);
        if (worstDeltaE > 0)
            line += QStringLiteral("; max delta E*ab %1 at (%2,%3,%4)").arg(worstDeltaE, 0, 'f', 3)
                        .arg(worstDeltaECode[0]).arg(worstDeltaECode[1]).arg(worstDeltaECode[2]);
        return line;
    }
};

// The shader model's output and Qt's for one source colour, both clamped as
// the display would show them.
struct Compared {
    std::array<float, 3> got, want;
    double error() const {
        return std::max({std::abs(got[0] - want[0]), std::abs(got[1] - want[1]), std::abs(got[2] - want[2])});
    }
};
Compared compare(const ColorLut& lut, const QColorTransform& reference, float r, float g, float b,
                 color::LutSampling sampling = {}) {
    const auto got = color::sampleLut(lut, r, g, b, sampling);
    const QRgbaFloat32 want = reference.map(QRgbaFloat32{r, g, b, 1.0f});
    return {{clamp01(got[0]), clamp01(got[1]), clamp01(got[2])}, {clamp01(want.r), clamp01(want.g), clamp01(want.b)}};
}
double lutError(const ColorLut& lut, const QColorTransform& reference, float r, float g, float b,
                color::LutSampling sampling = {}) {
    return compare(lut, reference, r, g, b, sampling).error();
}

// Every 8-bit level along the grey axis, the primaries and the secondaries,
// then a million random 8-bit colours; three samplers each, and delta E for
// exact weights when `lab` is given.
struct Measured {
    Errors exact, weights8, half;
};
Measured measure(const ColorLut& lut, const QColorTransform& reference, const Lab* lab = nullptr) {
    Measured m;
    const auto add = [&](int r, int g, int b) {
        const float fr = float(r) / 255.0f, fg = float(g) / 255.0f, fb = float(b) / 255.0f;
        const Compared exact = compare(lut, reference, fr, fg, fb);
        m.exact.add(exact.error(), r, g, b, lab ? lab->deltaE(exact.got, exact.want) : 0.0);
        m.weights8.add(lutError(lut, reference, fr, fg, fb, {8, false}), r, g, b);
        m.half.add(lutError(lut, reference, fr, fg, fb, {0, true}), r, g, b);
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
// a pure power curve makes hard, searched exhaustively rather than sampled.
Errors firstCellExhaustive(const ColorLut& lut, const QColorTransform& reference, const Lab* lab = nullptr) {
    Errors errors;
    const auto firstCell = [](int c) { return c >= 1 && c <= 3; };
    for (int r = 0; r < 256; ++r)
        for (int g = 0; g < 256; ++g)
            for (int b = 0; b < 256; ++b)
                if (firstCell(r) || firstCell(g) || firstCell(b)) {
                    const Compared c = compare(lut, reference, r / 255.0f, g / 255.0f, b / 255.0f);
                    errors.add(c.error(), r, g, b, lab ? lab->deltaE(c.got, c.want) : 0.0);
                }
    return errors;
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

void testQtFloatMapping() {
    // ColorLut.cpp relies on map(QRgbaFloat32) not clamping, so the shader
    // can interpolate first and clamp after.
    const auto toSrgb = QColorSpace(QColorSpace::ProPhotoRgb).transformationToColorSpace(QColorSpace::SRgb);
    const QRgbaFloat32 green = toSrgb.map(QRgbaFloat32{0.0f, 1.0f, 0.0f, 1.0f});
    say(QStringLiteral("measured: ProPhoto green in sRGB through Qt's float map: %1 %2 %3")
            .arg(green.r).arg(green.g).arg(green.b));
    check(green.r < -0.1f && green.g > 1.0f, QStringLiteral("QColorTransform::map(QRgbaFloat32) clamps"));
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
    // An sRGB display read from ICC bytes, the LUT built anyway (the pipeline
    // would skip it): every node, every 8-bit ramp and 1M random values.
    const QColorSpace display = viaIcc(QColorSpace(QColorSpace::SRgb));
    QElapsedTimer clock;
    clock.start();
    const auto lut = color::buildLut(QColorSpace::SRgb, display);
    say(QStringLiteral("measured: one 65^3 build (sRGB -> sRGB from ICC) took %1 ms").arg(clock.elapsed()));
    check(lut && lut->size == color::kLutSize && lut->rgba.size() == std::size_t(65 * 65 * 65 * 4), QStringLiteral("LUT layout"));
    double worstNode = 0;
    for (int b = 0; b < 65; ++b)
        for (int g = 0; g < 65; ++g)
            for (int r = 0; r < 65; ++r) {
                const float* node = &lut->rgba[(std::size_t(b * 65 + g) * 65 + r) * 4];
                worstNode = std::max({worstNode, double(std::abs(node[0] - r / 64.0f)),
                                      double(std::abs(node[1] - g / 64.0f)), double(std::abs(node[2] - b / 64.0f))});
                check(node[3] == 1.0f, QStringLiteral("an sRGB node is flagged out of the sRGB gamut"));
            }
    say(QStringLiteral("measured: identity LUT, worst node %1").arg(counts(worstNode)));
    check(worstNode < kBar, QStringLiteral("sRGB -> sRGB nodes are not the identity"));
    check(color::isNearIdentity(*lut), QStringLiteral("sRGB -> sRGB is not recognised as near identity"));

    double worstRamp = 0, worstRandom = 0, worstWeights8 = 0;
    for (int v = 0; v < 256; ++v) {
        const float c = float(v) / 255.0f;
        const float ramps[7][3] = {{c, c, c}, {c, 0, 0}, {0, c, 0}, {0, 0, c}, {0, c, c}, {c, 0, c}, {c, c, 0}};
        for (const auto& in : ramps) {
            const auto out = color::sampleLut(*lut, in[0], in[1], in[2]);
            const auto out8 = color::sampleLut(*lut, in[0], in[1], in[2], {8, false});
            for (int ch = 0; ch < 3; ++ch) {
                worstRamp = std::max(worstRamp, double(std::abs(out[ch] - in[ch])));
                worstWeights8 = std::max(worstWeights8, double(std::abs(out8[ch] - in[ch])));
            }
        }
    }
    std::mt19937 random(7);
    std::uniform_real_distribution<float> unit(0.0f, 1.0f);
    for (int i = 0; i < 1000000; ++i) {
        const float in[3] = {unit(random), unit(random), unit(random)};
        const auto out = color::sampleLut(*lut, in[0], in[1], in[2]);
        for (int ch = 0; ch < 3; ++ch) worstRandom = std::max(worstRandom, double(std::abs(out[ch] - in[ch])));
    }
    say(QStringLiteral("measured: identity through the shader model, ramps %1, 1M random %2, ramps with 8-bit weights %3")
            .arg(counts(worstRamp), counts(worstRandom), counts(worstWeights8)));
    check(worstRamp < kBar && worstRandom < kBar && worstWeights8 < kBar,
          QStringLiteral("the shader model does not reproduce the identity LUT"));

    // The classic sRGB profile stores its curves as 1024-entry tables, which
    // Qt does not recognise as sRGB: the pipeline must still treat it as one.
    QList<uint16_t> table;
    for (int i = 0; i < 1024; ++i) table.append(uint16_t(std::lround(srgbToLinear(i / 1023.0) * 65535.0)));
    const QColorSpace tabled = viaIcc(QColorSpace(QColorSpace::Primaries::SRgb, table));
    const auto nearIdentity = color::buildLut(QColorSpace::SRgb, tabled);
    double worstTabled = 0;
    for (int b = 0; b < 65; ++b)
        for (int g = 0; g < 65; ++g)
            for (int r = 0; r < 65; ++r) {
                const float* node = &nearIdentity->rgba[(std::size_t(b * 65 + g) * 65 + r) * 4];
                worstTabled = std::max({worstTabled, double(std::abs(node[0] - r / 64.0f)),
                                        double(std::abs(node[1] - g / 64.0f)), double(std::abs(node[2] - b / 64.0f))});
            }
    say(QStringLiteral("measured: sRGB with 1024-entry table curves, sameEncoding %1, worst node %2 (%3)")
            .arg(color::sameEncoding(QColorSpace::SRgb, tabled)).arg(counts(worstTabled))
            .arg(color::isNearIdentity(*nearIdentity) ? QStringLiteral("drawn as identity") : QStringLiteral("drawn through the LUT")));
    check(worstTabled < kBar, QStringLiteral("a table-curve sRGB display is not close to sRGB"));
    // sRGB whose red primary a profiler rounded 2e-5 differently: not Qt's
    // sRGB any more, but invisibly close, so the pipeline draws the identity.
    const QColorSpace rounded = viaIcc(QColorSpace(QPointF(0.3127, 0.3290), QPointF(0.64002, 0.33), QPointF(0.30, 0.60),
                                                   QPointF(0.15, 0.06), QColorSpace::TransferFunction::SRgb));
    const auto roundedLut = color::buildLut(QColorSpace::SRgb, rounded);
    say(QStringLiteral("measured: sRGB with red x off by 2e-5, sameEncoding %1, near identity %2")
            .arg(color::sameEncoding(QColorSpace::SRgb, rounded)).arg(color::isNearIdentity(*roundedLut)));
    check(color::isNearIdentity(*roundedLut), QStringLiteral("a profile within rounding of sRGB is not drawn as the identity"));
    // A visible difference must never collapse: Display P3 is not near sRGB.
    check(!color::isNearIdentity(*color::buildLut(QColorSpace::SRgb, viaIcc(QColorSpace::DisplayP3))),
          QStringLiteral("Display P3 collapsed to the identity"));
}

void testSwappedPrimaries() {
    // Red and green primaries exchanged: source red must come out as the
    // display's green, which catches a channel or axis swap anywhere.
    const QPointF white(0.3127, 0.3290), red(0.64, 0.33), green(0.30, 0.60), blue(0.15, 0.06);
    const QColorSpace swapped = viaIcc(QColorSpace(white, green, red, blue, QColorSpace::TransferFunction::SRgb));
    const auto lut = color::buildLut(QColorSpace::SRgb, swapped);
    const auto near = [](const std::array<float, 4>& got, float r, float g, float b) {
        return std::abs(got[0] - r) < kBar && std::abs(got[1] - g) < kBar && std::abs(got[2] - b) < kBar;
    };
    const auto redOut = color::sampleLut(*lut, 1, 0, 0), greenOut = color::sampleLut(*lut, 0, 1, 0);
    say(QStringLiteral("measured: swapped primaries, red -> %1 %2 %3, green -> %4 %5 %6")
            .arg(redOut[0]).arg(redOut[1]).arg(redOut[2]).arg(greenOut[0]).arg(greenOut[1]).arg(greenOut[2]));
    check(near(redOut, 0, 1, 0), QStringLiteral("swapped primaries: pure red does not land in G"));
    check(near(greenOut, 1, 0, 0), QStringLiteral("swapped primaries: pure green does not land in R"));
    check(near(color::sampleLut(*lut, 0, 0, 1), 0, 0, 1), QStringLiteral("swapped primaries: blue moved"));
    check(near(color::sampleLut(*lut, 1, 1, 1), 1, 1, 1), QStringLiteral("swapped primaries: white moved"));
    const auto mixed = color::sampleLut(*lut, 0.75f, 0.25f, 0.5f);
    check(near(mixed, 0.25f, 0.75f, 0.5f), QStringLiteral("swapped primaries: a mixed colour is not swapped"));
}

void testGamma26() {
    const QColorSpace gamma26 = viaIcc(QColorSpace(QColorSpace::Primaries::SRgb, 2.6f));
    const auto lut = color::buildLut(QColorSpace::SRgb, gamma26);
    const double expected = std::pow(srgbToLinear(0.5), 1.0 / 2.6);
    const auto grey = color::sampleLut(*lut, 0.5f, 0.5f, 0.5f);
    say(QStringLiteral("measured: gamma 2.6 display, sRGB 0.5 -> %1 (analytic %2, %3 counts)")
            .arg(grey[0], 0, 'f', 5).arg(expected, 0, 'f', 5).arg(std::lround(grey[0] * 255.0)));
    for (int ch = 0; ch < 3; ++ch)
        check(std::abs(grey[ch] - expected) < kBar && std::lround(grey[ch] * 255.0) == 141,
              QStringLiteral("gamma 2.6: sRGB 0.5 does not give 0.5527 (141 counts)"));
    const auto reference = QColorSpace(QColorSpace::SRgb).transformationToColorSpace(gamma26);
    const Lab lab(gamma26);
    const Measured m = measure(*lut, reference, &lab);
    const Errors firstCell = firstCellExhaustive(*lut, reference, &lab);
    say(QStringLiteral("measured: sRGB -> gamma 2.6: %1").arg(m.exact.text()));
    say(QStringLiteral("measured: sRGB -> gamma 2.6, every colour with a channel at codes 1-3: %1").arg(firstCell.text()));
    check(m.exact.worstAwayFromBlack < kBar, QStringLiteral("gamma 2.6: LUT error away from black is visible"));
    check(firstCell.worst < 7.0 / 255.0, QStringLiteral("gamma 2.6: the first-cell error grew"));
    // In light, the first-cell error is small: below delta E*ab 1 everywhere.
    check(m.exact.worstDeltaE < 1.0 && firstCell.worstDeltaE < 1.0, QStringLiteral("gamma 2.6: delta E*ab reached 1"));
}

void testWideGamutTargets() {
    struct Case {
        const char* name;
        QColorSpace display;
        bool pureGamma;
    } cases[] = {{"Display P3", viaIcc(QColorSpace::DisplayP3), false}, {"Adobe RGB", viaIcc(QColorSpace::AdobeRgb), true}};
    for (const auto& item : cases) {
        QElapsedTimer clock;
        clock.start();
        const auto lut = color::buildLut(QColorSpace::SRgb, item.display);
        const qint64 buildMs = clock.elapsed();
        // sRGB lies inside both gamuts, its red and blue exactly on Adobe
        // RGB's boundary: no node may be flagged.
        const double noise = boundaryNoise(QColorSpace::SRgb, item.display);
        say(QStringLiteral("measured: sRGB -> %1 built in %2 ms; boundary nodes at most %3 outside [0, 1] in linear light")
                .arg(item.name).arg(buildMs).arg(noise, 0, 'g', 3));
        check(clippedNodes(*lut) == 0 && noise < color::kGamutToleranceLinear,
              QStringLiteral("%1: sRGB nodes flagged out of gamut").arg(item.name));
        const auto reference = QColorSpace(QColorSpace::SRgb).transformationToColorSpace(item.display);
        const Lab lab(item.display);
        const Measured m = measure(*lut, reference, &lab);
        say(QStringLiteral("measured: sRGB -> %1, exact weights: %2").arg(item.name, m.exact.text()));
        say(QStringLiteral("measured: sRGB -> %1, 8-bit weights: %2").arg(item.name, m.weights8.text()));
        say(QStringLiteral("measured: sRGB -> %1, half-float texels: %2").arg(item.name, m.half.text()));
        if (!item.pureGamma) {
            check(m.exact.worst < kBar && m.weights8.worst < kBar && m.half.worst < kBar,
                  QStringLiteral("%1: LUT error is visible in 8 bits").arg(item.name));
        } else {
            // A pure power curve is steepest at zero: the first cell cannot
            // follow it, and no 65-node LUT indexed by encoded values can (see
            // README, "Display colour management"). Away from it the bar holds;
            // inside it the error is searched exhaustively and pinned so it
            // cannot grow unnoticed.
            check(m.exact.worstAwayFromBlack < kBar && m.weights8.worstAwayFromBlack < kBar && m.half.worstAwayFromBlack < kBar,
                  QStringLiteral("%1: LUT error away from black is visible in 8 bits").arg(item.name));
            const Errors firstCell = firstCellExhaustive(*lut, reference, &lab);
            say(QStringLiteral("measured: sRGB -> %1, every colour with a channel at codes 1-3: %2").arg(item.name, firstCell.text()));
            check(firstCell.worst < 3.6 / 255.0, QStringLiteral("%1: the first-cell error grew").arg(item.name));
            check(firstCell.worstDeltaE < 1.0, QStringLiteral("%1: delta E*ab reached 1 near black").arg(item.name));
        }
        check(m.exact.worstDeltaE < 1.0, QStringLiteral("%1: delta E*ab reached 1").arg(item.name));
    }
}

void testProPhotoSource() {
    const QColorSpace prophoto(QColorSpace::ProPhotoRgb);
    QElapsedTimer clock;
    clock.start();
    const auto lut = color::buildLut(prophoto, QColorSpace::SRgb);
    say(QStringLiteral("measured: ProPhoto -> sRGB built in %1 ms").arg(clock.elapsed()));
    const auto green = color::sampleLut(*lut, 0, 1, 0);
    check(green[3] == 0.0f, QStringLiteral("ProPhoto green is not flagged outside sRGB"));
    const auto reference = prophoto.transformationToColorSpace(QColorSpace::SRgb);
    const QRgbaFloat32 greyWant = reference.map(QRgbaFloat32{0.5f, 0.5f, 0.5f, 1.0f});
    const auto grey = color::sampleLut(*lut, 0.5f, 0.5f, 0.5f);
    check(grey[3] == 1.0f && std::abs(grey[0] - greyWant.r) < kBar && std::abs(grey[0] - grey[1]) < 1e-3f &&
              std::abs(grey[1] - grey[2]) < 1e-3f,
          QStringLiteral("ProPhoto grey is not a neutral sRGB grey (relative colorimetric)"));
    const int clipped = clippedNodes(*lut);
    say(QStringLiteral("measured: ProPhoto -> sRGB: %1 of %2 nodes outside sRGB; green -> %3 %4 %5 unclamped; grey 0.5 -> %6")
            .arg(clipped).arg(65 * 65 * 65).arg(green[0]).arg(green[1]).arg(green[2]).arg(grey[0], 0, 'f', 5));
    check(clipped > 0 && clipped < 65 * 65 * 65, QStringLiteral("ProPhoto -> sRGB gamut flags are all or nothing"));
    // sRGB colours re-encoded in ProPhoto: inside the gamut they must come
    // back as themselves and unflagged where every surrounding node is inside.
    const auto toProPhoto = QColorSpace(QColorSpace::SRgb).transformationToColorSpace(prophoto);
    Errors inGamut;
    const Lab lab(QColorSpace::SRgb);
    std::mt19937 random(11);
    std::uniform_int_distribution<int> code(0, 255);
    for (int i = 0; i < 1000000; ++i) {
        const int r = code(random), g = code(random), b = code(random);
        const QRgbaFloat32 p = toProPhoto.map(QRgbaFloat32{r / 255.0f, g / 255.0f, b / 255.0f, 1.0f});
        const auto out = color::sampleLut(*lut, p.r, p.g, p.b);
        const Compared c{{clamp01(out[0]), clamp01(out[1]), clamp01(out[2])}, {r / 255.0f, g / 255.0f, b / 255.0f}};
        inGamut.add(c.error(), r, g, b, lab.deltaE(c.got, c.want));
    }
    say(QStringLiteral("measured: sRGB colours carried in ProPhoto back to sRGB: %1").arg(inGamut.text()));
    // Known limit of an encoded -> encoded LUT, pinned rather than hidden:
    // where an sRGB channel passes through zero inside a ProPhoto cell, the
    // sRGB curve bends faster than 65 nodes can follow. A 1D output curve
    // after the 3D lookup removes it (README, "Display colour management").
    check(inGamut.worst < 16.0 / 255.0 && inGamut.worstDeltaE < 1.0, QStringLiteral("ProPhoto -> sRGB: the in-gamut error grew"));
    const QRgbaFloat32 skin = toProPhoto.map(QRgbaFloat32{0.8f, 0.6f, 0.5f, 1.0f});
    check(color::sampleLut(*lut, skin.r, skin.g, skin.b)[3] == 1.0f, QStringLiteral("an sRGB skin tone is flagged clipped"));
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

// Worst error of a LUT against Qt over a coarse 8-bit grid (no codes 1-3).
double coarseError(const ColorLut& lut, const QColorSpace& from, const QColorSpace& to) {
    const auto reference = from.transformationToColorSpace(to);
    double worst = 0;
    for (int r = 0; r < 256; r += 17)
        for (int g = 0; g < 256; g += 17)
            for (int b = 0; b < 256; b += 17)
                worst = std::max(worst, lutError(lut, reference, r / 255.0f, g / 255.0f, b / 255.0f));
    return worst;
}

void testPipeline(const QString& scratch) {
    const QString one = QStringLiteral("\\\\.\\DISPLAY1"), two = QStringLiteral("\\\\.\\DISPLAY2");
    const QByteArray p3 = iccOf(QColorSpace::DisplayP3), adobe = iccOf(QColorSpace::AdobeRgb);
    const QByteArray gamma26 = iccOf(QColorSpace(QColorSpace::Primaries::SRgb, 2.6f));
    const QColorSpace srgb(QColorSpace::SRgb), prophoto(QColorSpace::ProPhotoRgb);
    auto fake = std::make_shared<FakeMonitors>();
    fake->monitors[one] = monitor(one, QStringLiteral("Studio P3"), QStringLiteral("studio-p3.icc"), p3);
    fake->monitors[two] = monitor(two, QStringLiteral("Proof Adobe"), QStringLiteral("proof-adobe.icc"), adobe);

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
                say(QStringLiteral("  profile: \"%1\", model %2, primaries %3, transfer %4, primaryPoints() as returned: "
                                   "white %5,%6 red %7,%8 green %9,%10 blue %11,%12")
                        .arg(checked.space.description()).arg(int(checked.space.transformModel()))
                        .arg(int(checked.space.primaries())).arg(int(checked.space.transferFunction()))
                        .arg(points.whitePoint.x(), 0, 'f', 4).arg(points.whitePoint.y(), 0, 'f', 4)
                        .arg(points.redPoint.x(), 0, 'f', 4).arg(points.redPoint.y(), 0, 'f', 4)
                        .arg(points.greenPoint.x(), 0, 'f', 4).arg(points.greenPoint.y(), 0, 'f', 4)
                        .arg(points.bluePoint.x(), 0, 'f', 4).arg(points.bluePoint.y(), 0, 'f', 4));
                say(QStringLiteral("  sRGB source is identity on it: %1").arg(color::sameEncoding(QColorSpace::SRgb, checked.space)));
                // The LUT the canvas would get for an sRGB frame, measured
                // against Qt exactly as the tests measure synthetic displays.
                QElapsedTimer build;
                build.start();
                const auto lut = color::buildLut(QColorSpace::SRgb, checked.space);
                const qint64 buildMs = build.elapsed();
                const auto reference = QColorSpace(QColorSpace::SRgb).transformationToColorSpace(checked.space);
                const Lab lab(checked.space);
                const Measured m = measure(*lut, reference, &lab);
                say(QStringLiteral("  sRGB -> this display: built in %1 ms, %2 nodes clipped, near identity %3")
                        .arg(buildMs).arg(clippedNodes(*lut)).arg(color::isNearIdentity(*lut)));
                say(QStringLiteral("  sRGB -> this display, exact weights: ") + m.exact.text());
                say(QStringLiteral("  sRGB -> this display, 8-bit weights: ") + m.weights8.text());
                say(QStringLiteral("  sRGB -> this display, every colour with a channel at codes 1-3: ") +
                    firstCellExhaustive(*lut, reference, &lab).text());
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
    const bool probing = argc > 1 && QByteArray(argv[1]) == "--probe-display";
    // The probe wants the real Windows screens; the tests want no display.
    if (!probing) qputenv("QT_QPA_PLATFORM", "offscreen");
    QGuiApplication application(argc, argv);
    if (probing) return probe();
    try {
        // CTest passes a scratch directory in the build tree.
        const QString scratch = application.arguments().value(1);
        check(!scratch.isEmpty() && QDir().mkpath(scratch), QStringLiteral("pass a scratch directory"));
        testQtFloatMapping();
        testIdentity();
        testSwappedPrimaries();
        testGamma26();
        testWideGamutTargets();
        testProPhotoSource();
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
