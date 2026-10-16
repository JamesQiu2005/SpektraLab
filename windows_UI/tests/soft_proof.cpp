// The canvas soft proof against the export it proves, through the real engine.
//
// For a ProPhoto RGB session (the working space) and an sRGB one, every
// built-in recipe space and several displays, the canvas's proof -- the
// export's transform per pixel, then the display LUT for the recipe space
// (ProofTransform.hpp; spk::color::sampleProof is the CPU form the shader's
// PROOF variants are held to in spk_qt_color_canvas) -- is held to the
// per-pixel answer: the pixel's 16-bit code through exporting::convert's own
// transform into the recipe's 16-bit codes -- the file -- then Qt's
// colorimetric transform from the recipe space to the display, rounded to 8
// bits. Both read the colour the canvas reads (the frame's half float). The
// bar is one count. Then the gamut flag: synthetic out-of-gamut patches are
// flagged and in-gamut ones are not, the canvas's flag is the transform's own,
// and the pipeline serves the recipe space's display LUT only once it is this
// display's.
//
// Arguments: <resources> [--sweep]. --sweep also measures what a 3-D table
// of the same composite (source -> export -> display) would show -- the design
// the canvas does not use, and why: it prints the error per table form.
#include "ColorLut.hpp"
#include "ColorPipeline.hpp"
#include "DisplayColor.hpp"
#include "FrameImage.hpp"
#include "RecipeExport.hpp"
#include "SoftProof.hpp"
#include <QColorTransform>
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QFloat16>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRandomGenerator>
#include <QRgbaFloat>
#include <QThread>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <functional>
#include <map>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {
namespace color = spk::color;
namespace desktop = spk::desktop;
int checks = 0;
void check(bool ok, const QString& what) {
    ++checks;
    if(!ok) throw std::runtime_error(what.toUtf8().toStdString());
}
void say(const QString& line) { std::printf("%s\n", line.toUtf8().constData()); std::fflush(stdout); }

QColorSpace viaIcc(const QColorSpace& space) { return QColorSpace::fromIccProfile(space.iccProfile()); }
// This machine's display as its profile describes it (HP Z31x AdobeRGB D65:
// these primaries, D65, a pure gamma 2.2) -- spk_qt_color_core's replica.
QColorSpace hpZ31xReplica() {
    return viaIcc(QColorSpace(QPointF(0.3127, 0.3290), QPointF(0.64, 0.34), QPointF(0.21, 0.71), QPointF(0.15, 0.06),
                              QColorSpace::TransferFunction::Gamma, 2.2f));
}

// The display LUT the pipeline serves for `source` on `display`
// (ColorPipeline.cpp: the identity for the display's own encoding, else
// buildLut, the identity again when that comes out near it).
std::shared_ptr<const ColorLut> displayLut(const QColorSpace& source, const QColorSpace& display) {
    static const auto identity = std::make_shared<const ColorLut>();
    if(color::sameEncoding(source, display)) return identity;
    auto built = color::buildLut(source, display);
    if(!built || color::isNearIdentity(*built)) return identity;
    return built;
}

// The probe colours, as 16-bit codes: a grid, random colours, the shadows
// densely, and every edge of the cube (a channel at 0 or full) -- where the
// gamut map works hardest.
std::vector<std::array<std::uint16_t, 3>> probes(int randomCount) {
    std::vector<std::array<std::uint16_t, 3>> out;
    auto code = [](double v) { return std::uint16_t(std::lround(std::clamp(v, 0.0, 1.0) * 65535.0)); };
    for(int r = 0; r < 24; ++r) for(int g = 0; g < 24; ++g) for(int b = 0; b < 24; ++b)
        out.push_back({code(r / 23.0), code(g / 23.0), code(b / 23.0)});
    for(int r = 0; r < 12; ++r) for(int g = 0; g < 12; ++g) for(int b = 0; b < 12; ++b)
        out.push_back({code(r / 110.0), code(g / 110.0), code(b / 110.0)});
    for(int i = 0; i <= 64; ++i)
        for(double a : {0.0, 1.0}) for(double c : {0.0, 1.0}) {
            out.push_back({code(i / 64.0), code(a), code(c)});
            out.push_back({code(a), code(i / 64.0), code(c)});
            out.push_back({code(a), code(c), code(i / 64.0)});
        }
    QRandomGenerator random(20261016);
    for(int i = 0; i < randomCount; ++i)
        out.push_back({std::uint16_t(random.bounded(65536)), std::uint16_t(random.bounded(65536)), std::uint16_t(random.bounded(65536))});
    return out;
}
// The code the canvas reads: code / 65535 as a half float (FrameImage), back
// to the nearest 16-bit code for the reference's integer input.
float asHalf(std::uint16_t code) { return float(qfloat16(float(code) * (1.0f / 65535.0f))); }

struct Accuracy {
    int worst = 0;                // 8-bit counts
    double worstExact = 0;        // before rounding, counts
    qint64 overOne = 0, samples = 0;
    std::array<std::uint16_t, 3> at{};
    qint64 flagAgree = 0, flagged = 0;
};
QString codes(const std::array<std::uint16_t, 3>& c) { return QStringLiteral("(%1, %2, %3)").arg(c[0]).arg(c[1]).arg(c[2]); }

// The per-pixel answer for each probe -- the file's codes from the export's
// own transform (exporting::convert's arithmetic), shown through Qt -- and the
// flag the export's numbers give, against `shown`: what the canvas computes.
using Canvas = std::function<void(const float* encoded, std::size_t n, float* rgba)>;
Accuracy measure(const Canvas& shown, const spkhost::OutputTransform& transform, const QColorSpace& target,
                 const QColorSpace& display, const std::vector<std::array<std::uint16_t, 3>>& points) {
    const std::size_t n = points.size();
    std::vector<float> in(n * 3);
    std::vector<std::uint16_t> rgba(n * 4);
    for(std::size_t i = 0; i < n; ++i) {
        for(int k = 0; k < 3; ++k) {
            in[i*3+k] = asHalf(points[i][k]);
            rgba[i*4+k] = std::uint16_t(std::lround(in[i*3+k] * 65535.0f));
        }
        rgba[i*4+3] = 65535;
    }
    std::vector<float> linear; std::vector<std::uint16_t> file;
    transform.to_linear(rgba.data(), std::uint32_t(n), 1, std::uint32_t(n), linear);
    transform.encode_rgba16(linear, file);
    std::vector<float> codesIn(n * 3), unused(n * 3);
    for(std::size_t i = 0; i < n * 3; ++i) codesIn[i] = rgba[(i / 3) * 4 + i % 3] / 65535.0f;
    std::vector<std::uint8_t> outside(n);
    transform.transform_encoded(codesIn.data(), n, unused.data(), outside.data());
    std::vector<float> got(n * 4);
    shown(in.data(), n, got.data());
    const QColorTransform toDisplay = target.transformationToColorSpace(display);
    Accuracy a;
    for(std::size_t i = 0; i < n; ++i) {
        const QRgbaFloat32 want = toDisplay.map(QRgbaFloat32{file[i*4] / 65535.0f, file[i*4+1] / 65535.0f, file[i*4+2] / 65535.0f, 1.0f});
        const float w[3] = {want.r, want.g, want.b};
        int diff = 0; double exact = 0;
        for(int k = 0; k < 3; ++k) {
            const double g = std::clamp(double(got[i*4+k]), 0.0, 1.0), e = std::clamp(double(w[k]), 0.0, 1.0);
            diff = std::max(diff, int(std::abs(std::lround(g * 255.0) - std::lround(e * 255.0))));
            exact = std::max(exact, std::abs(g - e) * 255.0);
        }
        if(diff > a.worst) { a.worst = diff; a.at = points[i]; }
        a.worstExact = std::max(a.worstExact, exact);
        a.overOne += diff > 1; ++a.samples;
        bool clipped = false;
        for(int k = 0; k < 3; ++k) {
            const float l = linear[i*3+k];
            if(!(l >= -kProofClipTolerance && l <= 1.0f + kProofClipTolerance)) clipped = true;
        }
        const bool fileFlag = outside[i] || clipped, canvasFlag = got[i*4+3] < 0.5f;
        a.flagAgree += fileFlag == canvasFlag; a.flagged += canvasFlag;
    }
    return a;
}

// --- --sweep: the 3-D table the canvas does not use --------------------------
// The whole composite -- source -> export transform -> the file's clamp ->
// display -- sampled on a grid and drawn through the display LUT contract's
// curved form: a shaper (the source's decode, or the encoded value itself), a
// table of display-linear light, the display's encode. What it measures is
// the reason the proof runs per pixel (ProofTransform.hpp).
std::shared_ptr<ColorLut> compositeLut(const ProofTransform& proof, const QColorSpace& display, int n, bool decodeShaper) {
    const QColorSpace& source = proof.source;
    const QColorSpace sourceLinear = source.withTransferFunction(QColorSpace::TransferFunction::Linear);
    const QColorSpace displayLinear = display.withTransferFunction(QColorSpace::TransferFunction::Linear);
    const QColorSpace targetLinear = proof.target.withTransferFunction(QColorSpace::TransferFunction::Linear);
    const QColorTransform decode = source.transformationToColorSpace(sourceLinear);
    const QColorTransform toSource = sourceLinear.transformationToColorSpace(source);
    const QColorTransform encode = displayLinear.transformationToColorSpace(display);
    const QColorTransform toDisplay = targetLinear.transformationToColorSpace(displayLinear);
    auto lut = std::make_shared<ColorLut>();
    lut->key = color::nextLutKey(); lut->size = n; lut->rgba.resize(std::size_t(n) * n * n * 4);
    lut->curveSize = color::kCurveSize;
    lut->shaper.resize(std::size_t(color::kCurveSize) * 4); lut->output.resize(std::size_t(color::kCurveSize) * 4);
    for(int i = 0; i < color::kCurveSize; ++i) {
        const float x = float(i) / float(color::kCurveSize - 1), u = x * x;
        const QRgbaFloat32 s = decodeShaper ? decode.map(QRgbaFloat32{x, x, x, 1.0f}) : QRgbaFloat32{x, x, x, 1.0f};
        const QRgbaFloat32 o = encode.map(QRgbaFloat32{u, u, u, 1.0f});
        float* sp = &lut->shaper[std::size_t(i) * 4]; float* op = &lut->output[std::size_t(i) * 4];
        sp[0] = s.r, sp[1] = s.g, sp[2] = s.b, sp[3] = 1; op[0] = o.r, op[1] = o.g, op[2] = o.b, op[3] = 1;
    }
    toDisplay.map(QRgbaFloat32{0.5f, 0.5f, 0.5f, 1.0f}); toSource.map(QRgbaFloat32{0.5f, 0.5f, 0.5f, 1.0f});
    auto slices = [&](int b0, int b1) {
        std::vector<float> e(std::size_t(n) * n * 3), l(std::size_t(n) * n * 3);
        for(int b = b0; b < b1; ++b) {
            for(int g = 0; g < n; ++g) for(int r = 0; r < n; ++r) {
                const QRgbaFloat32 t{float(r) / (n - 1), float(g) / (n - 1), float(b) / (n - 1), 1.0f};
                const QRgbaFloat32 v = decodeShaper ? toSource.map(t) : t;
                float* p = &e[(std::size_t(g) * n + r) * 3];
                p[0] = std::clamp(v.r, 0.0f, 1.0f), p[1] = std::clamp(v.g, 0.0f, 1.0f), p[2] = std::clamp(v.b, 0.0f, 1.0f);
            }
            proof.evaluate(e.data(), std::size_t(n) * n, l.data(), nullptr);
            for(std::size_t i = 0; i < std::size_t(n) * n; ++i) {
                float c[3];
                for(int k = 0; k < 3; ++k) { const float x = l[i*3+k]; c[k] = x > 0 ? (x < 1 ? x : 1) : 0; }
                const QRgbaFloat32 d = toDisplay.map(QRgbaFloat32{c[0], c[1], c[2], 1.0f});
                float* o = &lut->rgba[(std::size_t(b) * n * n + i) * 4];
                o[0] = d.r, o[1] = d.g, o[2] = d.b, o[3] = 1;
            }
        }
    };
    const int threads = std::clamp(int(std::thread::hardware_concurrency()), 1, 8), chunk = (n + threads - 1) / threads;
    std::vector<std::thread> pool;
    for(int b0 = chunk; b0 < n; b0 += chunk) pool.emplace_back(slices, b0, std::min(n, b0 + chunk));
    slices(0, std::min(n, chunk));
    for(auto& t : pool) t.join();
    return lut;
}

// A pipeline on a simulated monitor, as spk_qt_color_core drives one.
class Monitor final : public color::ProfileSource {
public:
    QByteArray icc;
    color::DisplayInfo query(const QString& screenId) override {
        color::DisplayInfo info;
        info.screenId = screenId; info.monitorName = QStringLiteral("Replica");
        info.profilePath = QStringLiteral("replica.icc"); info.icc = icc;
        info.profileSize = icc.size(); info.profileModifiedMs = 1; info.lookup = QStringLiteral("simulated");
        return info;
    }
};
class TestPipeline final : public ColorPipeline {
public:
    TestPipeline() : ColorPipeline(nullptr) {}
};
bool waitFor(const std::function<bool()>& done, int timeoutMs) {
    QElapsedTimer clock; clock.start();
    while(!done()) {
        if(clock.elapsed() > timeoutMs) return false;
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        QThread::msleep(1);
    }
    return true;
}
}

int main(int argc, char** argv) {
    qputenv("QT_QPA_PLATFORM", QByteArray("offscreen"));
    QGuiApplication app(argc, argv);
    QJsonObject report;
    try {
        const auto args = app.arguments();
        if(args.size() < 2) throw std::runtime_error("usage: spk_qt_soft_proof_test <resources> [--sweep]");
        const bool sweep = args.contains(QStringLiteral("--sweep"));
        spk_engine* engine = spk_engine_create(args[1].toUtf8().constData(), nullptr);
        check(engine != nullptr, QStringLiteral("engine: ") + spk_last_error(nullptr));
        const auto points = probes(sweep ? 200000 : 60000);
        struct Display { QString name; QColorSpace space; };
        const Display displays[] = {{"sRGB", QColorSpace(QColorSpace::SRgb)},
                                    {"Display P3", viaIcc(QColorSpace::DisplayP3)},
                                    {"Adobe RGB", viaIcc(QColorSpace::AdobeRgb)},
                                    {"HP Z31x replica", hpZ31xReplica()}};
        struct Space { const char* engine; const char* name; };
        const Space recipes[] = {{"sRGB", "sRGB"}, {"Display P3", "Display P3"}, {"Adobe RGB (1998)", "Adobe RGB (1998)"},
                                 {"ProPhoto RGB", "ROMM RGB (ProPhoto)"}};
        QJsonObject accuracy;
        int worstOverall = 0;
        for(const char* session : {"ProPhoto RGB", "sRGB"}) {
            const desktop::OutputEncoding from{session, true};
            for(const auto& recipe : recipes) {
                QElapsedTimer made; made.start();
                const auto proof = desktop::proofing::makeProofTransform(engine, from, recipe.engine, QString::fromLatin1(recipe.name));
                const qint64 madeMs = made.elapsed();
                check(proof && proof->evaluate && proof->encodeTarget && proof->source == desktop::display::colorSpace(from) &&
                      proof->target == desktop::display::colorSpace({recipe.engine, true}) &&
                      proof->identity == (std::string(session) == recipe.engine),
                      QStringLiteral("%1 -> %2: no proof transform").arg(session, recipe.engine));
                // The shader's numbers are the transform's: the C_max table
                // whole, the three matrices, and CAM16 on exactly where the
                // export compresses (out of a wider space).
                const auto& k = proof->kernel;
                check(k.cmax.size() == std::size_t(k.cmaxRows) * k.cmaxCols && (proof->identity || k.cmaxRows > 1),
                      QStringLiteral("%1 -> %2: the kernel carries no C_max table").arg(session, recipe.engine));
                const auto transform = desktop::exporting::exportTransform(session, recipe.engine, engine);
                check(k.cam16 == transform.compresses(), QStringLiteral("%1 -> %2: the kernel's CAM16 switch is not the export's")
                                                              .arg(session, recipe.engine));
                for(const auto& display : displays) {
                    const auto lut = displayLut(proof->target, display.space);
                    QElapsedTimer clock; clock.start();
                    const auto a = measure([&](const float* e, std::size_t n, float* out) { color::sampleProof(*lut, *proof, e, n, out); },
                                           transform, proof->target, display.space, points);
                    const qint64 ms = clock.elapsed();
                    const QString name = QStringLiteral("%1 session -> %2 on %3").arg(session, recipe.engine, display.name);
                    say(QStringLiteral("  %1: %2 probes, max %3 count(s) (%4 exact) at %5, %6 over one; flag agrees on %7 of %8 (%9 flagged); "
                                       "%10 ms per pixel x 1e6")
                            .arg(name).arg(a.samples).arg(a.worst).arg(a.worstExact, 0, 'f', 3).arg(codes(a.at)).arg(a.overOne)
                            .arg(a.flagAgree).arg(a.samples).arg(a.flagged).arg(1e6 * double(ms) / double(a.samples), 0, 'f', 0));
                    accuracy[name] = QJsonObject{{"max_counts", a.worst}, {"max_exact_counts", a.worstExact},
                                                 {"flag_agreement", double(a.flagAgree) / a.samples},
                                                 {"flagged_fraction", double(a.flagged) / a.samples}, {"transform_ms", double(madeMs)}};
                    worstOverall = std::max(worstOverall, a.worst);
                    check(a.worst <= 1, QStringLiteral("%1: the proof is %2 counts from the export at %3").arg(name).arg(a.worst).arg(codes(a.at)));
                    // The canvas's flag is the export's numbers' own; only a
                    // colour within a 16-bit code of the boundary may differ.
                    check(a.samples - a.flagAgree <= a.samples / 2000,
                          QStringLiteral("%1: the flag disagrees with the export's on %2 probes").arg(name).arg(a.samples - a.flagAgree));
                    if(proof->identity) check(a.flagged == 0, QStringLiteral("%1: an identity proof flags colours").arg(name));
                    if(sweep && !proof->identity) {
                        for(const auto& [formName, form] : std::map<QString, std::pair<int, bool>>{
                                {QStringLiteral("table 65, decode shaper"), {65, true}}, {QStringLiteral("table 65, encoded shaper"), {65, false}},
                                {QStringLiteral("table 33, decode shaper"), {33, true}}, {QStringLiteral("table 33, encoded shaper"), {33, false}}}) {
                            const auto table = compositeLut(*proof, display.space, form.first, form.second);
                            const auto b = measure([&](const float* e, std::size_t n, float* out) {
                                for(std::size_t i = 0; i < n; ++i) {
                                    const auto s = color::sampleLut(*table, e[i*3], e[i*3+1], e[i*3+2]);
                                    out[i*4] = s[0]; out[i*4+1] = s[1]; out[i*4+2] = s[2]; out[i*4+3] = 1;
                                }
                            }, transform, proof->target, display.space, points);
                            say(QStringLiteral("    sweep, a %1: max %2 counts (%3 exact) at %4, %5 of %6 probes over one")
                                    .arg(formName).arg(b.worst).arg(b.worstExact, 0, 'f', 3).arg(codes(b.at)).arg(b.overOne).arg(b.samples));
                        }
                    }
                }
            }
        }
        report["accuracy"] = accuracy;
        report["worst_counts"] = worstOverall;

        // ---- the gamut flag on synthetic patches ----
        {
            const desktop::OutputEncoding from{"ProPhoto RGB", true};
            const auto srgb = desktop::proofing::makeProofTransform(engine, from, "sRGB", QStringLiteral("sRGB"));
            const auto p3 = desktop::proofing::makeProofTransform(engine, from, "Display P3", QStringLiteral("Display P3"));
            const auto prophoto = desktop::proofing::makeProofTransform(engine, from, "ProPhoto RGB", QStringLiteral("ProPhoto"));
            const auto display = hpZ31xReplica();
            struct Patch { const char* name; float rgb[3]; bool inSrgb, inP3; };
            // ProPhoto codes. Its green primary and a deep green lie far
            // outside sRGB and P3; a saturated ProPhoto blue too. A mid grey and
            // a skin tone lie well inside both.
            const Patch patches[] = {{"ProPhoto green", {0.0f, 1.0f, 0.0f}, false, false},
                                     {"deep green", {0.15f, 0.8f, 0.2f}, false, false},
                                     {"ProPhoto blue", {0.1f, 0.1f, 0.9f}, false, false},
                                     {"mid grey", {0.5f, 0.5f, 0.5f}, true, true},
                                     {"skin tone", {0.62f, 0.52f, 0.44f}, true, true}};
            QJsonObject flags;
            for(const auto& p : patches) {
                float shown[4], shownP3[4], shownPro[4];
                color::sampleProof(*displayLut(srgb->target, display), *srgb, p.rgb, 1, shown);
                color::sampleProof(*displayLut(p3->target, display), *p3, p.rgb, 1, shownP3);
                color::sampleProof(*displayLut(prophoto->target, display), *prophoto, p.rgb, 1, shownPro);
                say(QStringLiteral("  gamut flag, %1 (%2, %3, %4): sRGB %5, Display P3 %6, ProPhoto %7 (1 = kept)")
                        .arg(p.name).arg(p.rgb[0]).arg(p.rgb[1]).arg(p.rgb[2]).arg(shown[3]).arg(shownP3[3]).arg(shownPro[3]));
                check((shown[3] == 1.0f) == p.inSrgb, QStringLiteral("gamut flag: %1 into sRGB").arg(p.name));
                check((shownP3[3] == 1.0f) == p.inP3, QStringLiteral("gamut flag: %1 into Display P3").arg(p.name));
                check(shownPro[3] == 1.0f, QStringLiteral("gamut flag: %1 flagged into its own space").arg(p.name));
                flags[p.name] = QJsonObject{{"sRGB", shown[3]}, {"Display P3", shownP3[3]}};
            }
            report["patch_flags"] = flags;
        }

        // ---- the pipeline serves the recipe space's LUT once it is this display's ----
        {
            auto monitor = std::make_shared<Monitor>();
            monitor->icc = hpZ31xReplica().iccProfile();
            TestPipeline pipeline;
            pipeline.setProfileSourceForTesting(monitor);
            pipeline.setScreenForTesting(QStringLiteral("\\\\.\\DISPLAY1"));
            const QColorSpace srgb(QColorSpace::SRgb);
            QElapsedTimer clock; clock.start();
            check(!pipeline.readyLut(srgb), QStringLiteral("a LUT was ready before it was built"));
            check(waitFor([&] { return bool(pipeline.readyLut(srgb)); }, 30000), QStringLiteral("the recipe space's LUT never landed"));
            report["pipeline_lut_ms"] = double(clock.elapsed());
            check(pipeline.readyLut(srgb) == pipeline.lut(srgb) && !pipeline.readyLut(srgb)->isIdentity(),
                  QStringLiteral("readyLut is not the served LUT"));
            const QColorSpace display = pipeline.targetColorSpace();
            check(pipeline.readyLut(display) && pipeline.readyLut(display)->isIdentity(),
                  QStringLiteral("the display's own encoding is not ready as the identity"));
        }
        spk_engine_destroy(engine);
        report["checks"] = checks; report["passed"] = true;
        std::printf("%s\nspk_qt_soft_proof: %d checks passed\n", QJsonDocument(report).toJson().constData(), checks);
        return 0;
    } catch(const std::exception& e) {
        std::fprintf(stderr, "FAILED after %d checks: %s\n", checks, e.what());
        return 1;
    }
}
