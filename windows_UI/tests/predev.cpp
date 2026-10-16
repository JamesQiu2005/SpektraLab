// The Pre-Dev rail's backend without a RAW fixture.
//
//  - the Latitude readout on a hand-made reply (shares, the separation band's
//    core, the summary line, the placed histogram);
//  - a neutral log ramp, -10..+8 stops about mid-grey, through the real
//    engine with the meter off, so every number has a known answer: the
//    scene's robust extremes, the shares below/within/above the medium, the
//    engine's Fit against ours on the same measurement, the placement window,
//    the committed curve's placed histogram against the engine's, and
//    spk_solve's report (and that it writes nothing to the session);
//  - the Tone Mask curve's calibration, the white-balance rules, and the
//    eyedropper's geometry against FrameOutput's own pixels;
//  - the controller's Pre-Dev API with no photograph open.
#include "PreviewController.hpp"
#include "LatitudeModel.hpp"
#include "WhiteBalance.hpp"
#include "FrameOutput.hpp"
#include "core/json.hpp"
#include <QCoreApplication>
#include <QDir>
#include <QEventLoop>
#include <QTimer>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>

namespace desktop = spk::desktop;
namespace predev = spk::desktop::predev;
using spk::Json;

namespace {
int checks = 0;
void check(bool value, const std::string& message) {
    ++checks;
    if (!value) throw std::runtime_error(message);
}
bool near(double a, double b, double tolerance) { return std::abs(a - b) <= tolerance; }
double ms(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
}
Json parsed(const std::string& text) {
    Json value;
    std::string error;
    check(Json::parse(text, value, error), "not JSON: " + error);
    return value;
}
Json numbers(const std::vector<double>& values) {
    Json out = Json::array();
    for (double v : values) out.push(Json(v));
    return out;
}

// --- the readout on a hand-made reply -------------------------------------------

void readout_rules() {
    // The print's L* rises as 50 + 25 tanh(ev / 2): separation peaks at 0
    // and is half its peak at +-2 acosh(sqrt 2) = +-1.7627 stops.
    std::vector<double> ev, y;
    for (int i = 0; i < 128; ++i) {
        const double e = -8.0 + 16.0 * i / 127.0;
        const double lstar = 50.0 + 25.0 * std::tanh(e / 2.0);
        ev.push_back(e);
        y.push_back(0.81 * std::pow((lstar + 16.0) / 116.0, 3.0));
    }
    // A quarter of the frame under the medium, half in it, a quarter over.
    std::vector<double> fractions(128, 0.0);
    fractions[40] = 0.25;  // centre -5.875
    fractions[64] = 0.5;   // +0.125
    fractions[90] = 0.25;  // +6.625
    Json medium = Json::object(), scene = Json::object(), histogram = Json::object(), fit = Json::object();
    medium.set("shadow_ev", Json(-2.5));
    medium.set("highlight_ev", Json(2.0));
    medium.set("y_black", Json(0.81 * std::pow(41.0 / 116.0, 3.0)));
    medium.set("y_white", Json(0.81));
    medium.set("ramp_ev", numbers(ev));
    medium.set("ramp_y", numbers(y));
    for (const auto& [key, value] : {std::pair{"p0_1", -5.9}, {"p1", -5.8}, {"p50", 0.1}, {"p99", 6.6}, {"p99_9", 6.7}})
        scene.set(key, Json(value));
    histogram.set("lo_ev", Json(-16.0));
    histogram.set("hi_ev", Json(16.0));
    histogram.set("fractions", numbers(fractions));
    scene.set("histogram", histogram);
    fit.set("valid", Json(true));
    fit.set("issues", Json::array());
    Json reply = Json::object();
    reply.set("medium", medium);
    reply.set("scene", scene);
    reply.set("fit", fit);

    predev::LatitudeReading reading;
    std::string error;
    check(predev::readLatitude(reply, reading, error), "reading a reply: " + error);
    spk::SceneLatitudeParams identity;
    const auto r = predev::readout(reading, identity);
    check(r.centres.size() == 128 && near(r.binWidth, 0.25, 1e-15) && near(r.centres[0], -15.875, 1e-12) &&
          near(r.centres[64], 0.125, 1e-12), "bins on the stop axis");
    check(near(r.below, 0.25, 1e-12) && near(r.within, 0.5, 1e-12) && near(r.above, 0.25, 1e-12),
          "below / within / above");
    // Within one ramp step (16/127 stops): the band is read at step midpoints.
    check(r.core && near(r.core->first, -1.7627, 0.13) && near(r.core->second, 1.7627, 0.13),
          "full separation is not where the lightness change is half its peak: " +
              (r.core ? std::to_string(r.core->first) + " .. " + std::to_string(r.core->second) : std::string("none")));
    double peak = 0;
    for (const auto& s : r.separation) peak = std::max(peak, s.second);
    check(near(peak, 1.0, 1e-12) && r.separation.size() == 127, "the separation band is not over its peak");
    auto summary = predev::latitudeSummary(r);
    summary.replace(QChar(0x00A0), QLatin1Char(' '));
    check(summary.startsWith(QStringLiteral("4.50 stops held · −2.50 – +2.00 · full separation −")),
          "summary line: " + summary.toStdString());
    const auto view = predev::latitudeVariant(r);
    check(view.value("fractions").toList().size() == 128 && view.value("hasCore").toBool() &&
          near(view.value("heldStops").toDouble(), 4.5, 1e-12) && near(view.value("under").toDouble(), 0, 0) &&
          near(view.value("over").toDouble(), 0, 0), "the QML view");
    // A committed highlight curve carries the top of the frame down; the
    // shares are of what the render does, and nothing is lost.
    spk::SceneLatitudeParams curve;
    curve.active = true;
    curve.highlight_knee = 1.0;
    curve.highlight_room = 1.0;
    const auto placed = predev::readout(reading, curve);
    double mass = 0;
    for (double f : placed.fractions) mass += f;
    check(placed.above < r.above && near(mass, 1.0, 1e-12), "the placed histogram does not follow the curve");
    curve.active = false;  // an inactive curve renders nothing
    check(predev::readout(reading, curve).fractions == r.fractions, "an inactive curve moved the histogram");
}

// --- a ramp through the engine --------------------------------------------------

struct Engine {
    std::unique_ptr<spk_engine, decltype(&spk_engine_destroy)> engine{nullptr, &spk_engine_destroy};
    std::unique_ptr<spk_session, decltype(&spk_session_release)> session{nullptr, &spk_session_release};
};

std::string call_latitude(spk_session* session, double highlight, double shadow) {
    Json request = Json::object();
    request.set("highlight_pull_back", Json(highlight));
    request.set("shadow_pull_back", Json(shadow));
    char* out = nullptr;
    const auto status = spk_scene_latitude(session, request.dump().c_str(), &out);
    check(status == SPK_OK && out, std::string("spk_scene_latitude: ") + spk_last_error(nullptr));
    std::string text(out);
    spk_string_free(out);
    return text;
}

void render(spk_session* session) {
    spk_result result{};
    check(spk_render(session, "full", &result) == SPK_OK, std::string("render: ") + spk_last_error(nullptr));
    spk_result_free(&result);
}

void engine_ramp(const std::filesystem::path& resources) {
    const auto catalog = desktop::read_catalog(resources);
    Engine e;
    const auto root = resources.u8string();
    e.engine.reset(spk_engine_create(reinterpret_cast<const char*>(root.c_str()), nullptr));
    check(bool(e.engine), std::string("engine: ") + spk_last_error(nullptr));
    // A neutral ramp from 2^-10 to 2^+8 times mid-grey, even in stops, with
    // the meter off: the scene axis is then the ramp's own stops.
    constexpr std::uint32_t width = 1024, height = 64;
    std::vector<float> rgb(std::size_t(width) * height * 3);
    for (std::uint32_t y = 0; y < height; ++y)
        for (std::uint32_t x = 0; x < width; ++x) {
            const float v = float(0.184 * std::exp2(-10.0 + 18.0 * (x + 0.5) / width));
            float* p = rgb.data() + (std::size_t(y) * width + x) * 3;
            p[0] = p[1] = p[2] = v;
        }
    const spk_image input{rgb.data(), width, height, 3};
    desktop::RenderSettings settings;
    settings.grain_active = false;
    settings.glare_active = false;
    settings.set("auto_exposure", false);
    e.session.reset(spk_open(e.engine.get(), &input, desktop::opening_params(settings, catalog).dump().c_str(), nullptr));
    check(bool(e.session), std::string("open: ") + spk_last_error(nullptr));
    render(e.session.get());

    auto started = std::chrono::steady_clock::now();
    const auto first = call_latitude(e.session.get(), 0, 0);
    const double cold = ms(started);
    started = std::chrono::steady_clock::now();
    const auto again = call_latitude(e.session.get(), 0, 0);
    const double warm = ms(started);
    check(first == again, "a repeated measurement differs");
    predev::LatitudeReading reading;
    std::string error;
    check(predev::readLatitude(parsed(first), reading, error), "reading the ramp: " + error);
    const auto r = predev::readout(reading, spk::SceneLatitudeParams{});
    std::printf("ramp: medium %.3f .. %+.3f stops (%.2f held), scene P0.1 %.3f P99.9 %+.3f; below %.4f within %.4f "
                "above %.4f; spk_scene_latitude %.1f ms cold, %.1f ms cached\n",
                reading.shadowEv, reading.highlightEv, reading.highlightEv - reading.shadowEv, reading.p01,
                reading.p999, r.below, r.within, r.above, cold, warm);
    check(near(reading.p01, -9.982, 0.2) && near(reading.p999, 7.982, 0.2), "the ramp's robust extremes");
    check(reading.shadowEv > -10 && reading.highlightEv < 8 && reading.shadowEv < 0 && reading.highlightEv > 0,
          "the medium's boundaries are not inside the ramp");
    // An even ramp: each share is its span of the 18 stops.
    check(near(r.below, (reading.shadowEv + 10.0) / 18.0, 0.02) && near(r.above, (8.0 - reading.highlightEv) / 18.0, 0.02) &&
          near(r.below + r.within + r.above, 1.0, 1e-9), "the shares are not the ramp's spans");

    // Our Fit is the engine's: the same knees and rooms on the same numbers.
    const spk::SceneLatitudeParams base;  // the session's curve: the defaults
    const double minimum = reading.p999 - reading.highlightEv;
    const double asked = std::min(minimum + 1.0, 7.5);
    const auto ours = predev::fit(reading, asked, 0, base);
    const auto engine = parsed(call_latitude(e.session.get(), asked, 0));
    const Json& theirs = engine.at("fit");
    check(ours.valid() && theirs.at("valid").as_bool(), "a pull-back one stop past the minimum was refused");
    check(near(ours.highlight.knee, theirs.at("highlight").at("knee").as_double(), 1e-12) &&
          near(ours.highlight.room, theirs.at("highlight").at("room").as_double(), 1e-12) &&
          near(ours.highlight.landing, theirs.at("highlight").at("landing_ev").as_double(), 1e-12),
          "the Fit here and the engine's disagree");
    const auto curve = predev::committedCurve(ours);
    const Json& delta = theirs.at("params_delta");
    check(curve.active == delta.at("scene_latitude_active").as_bool() &&
          curve.highlight_knee == delta.at("scene_latitude_highlight_knee").as_double() &&
          curve.highlight_room == delta.at("scene_latitude_highlight_room").as_double() &&
          curve.shadow_room == delta.at("scene_latitude_shadow_room").as_double(), "the committed curve is not the engine's delta");
    std::printf("ramp: highlight pull-back %.3f (minimum %.3f): knee %+.4f room %.4f, the scene's top lands at %+.4f\n",
                asked, minimum, ours.highlight.knee, ours.highlight.room, ours.highlight.landing);

    // The window the slider is held to, and a refusal in the row's words.
    const auto top = predev::placementWindow(reading, predev::Side::highlight, 0, base);
    check(top.hasSpan && top.least > minimum && top.least <= asked && asked <= top.most && top.most <= 8.0,
          "the highlight window");
    const auto below = top.landing(minimum * 0.5);
    check(below.first == top.least && below.second && below.second->side == "highlight", "a value under the window");
    const auto words = predev::refusalMessage(*below.second, predev::Side::highlight, minimum);
    check(words && words->rfind("Pull back", 0) == 0, "the refusal has no words");
    check(!predev::refusalMessage(*below.second, predev::Side::shadow, minimum), "a highlight refusal shown on the shadow row");
    check(top.landing(0).first == 0 && !top.landing(0).second, "0 is the side off, always taken");
    std::printf("ramp: highlight window %.2f .. %.2f, under it: %s\n", top.least, top.most, words->c_str());
    // The shadow side: the lift is bounded at max_lift (4 stops), so a ramp
    // whose bottom is further under the medium than that has no window.
    const double shadowMinimum = reading.shadowEv - reading.p01;
    const auto bottom = predev::placementWindow(reading, predev::Side::shadow, 0, base);
    if (shadowMinimum >= base.max_lift) {
        check(!bottom.hasSpan && bottom.below.code == predev::PlacementWindow::noWindowCode &&
              bottom.landing(2.0).first == 0, "a shadow side past the lift bound offered a window");
        const auto why = predev::refusalMessage(bottom.below, predev::Side::shadow, shadowMinimum);
        check(why && why->find("too far under") != std::string::npos, "no-window words");
    } else {
        check(bottom.hasSpan, "a shadow side inside the lift bound offered no window");
    }

    // Committed, the render's placed histogram is the engine's.
    check(spk_set_params(e.session.get(), delta.dump().c_str(), nullptr) == SPK_OK,
          std::string("commit: ") + spk_last_error(nullptr));
    render(e.session.get());
    const auto after = parsed(call_latitude(e.session.get(), asked, 0));
    predev::LatitudeReading placedReading;
    check(predev::readLatitude(after, placedReading, error), "reading after the commit: " + error);
    std::vector<double> engineFractions;
    for (const auto& v : after.at("scene").at("histogram").at("placed_fractions").items()) engineFractions.push_back(v.as_double());
    const auto placed = predev::readout(placedReading, curve);
    check(engineFractions.size() == 128 && placed.fractions == engineFractions, "the placed histogram differs from the engine's");
    check(placedReading.fractions == reading.fractions, "the scene moved: it is measured before the curve");
    check(placed.above < r.above, "the placement did not bring the top inside");
    std::printf("ramp: placed, above %.4f -> %.4f\n", r.above, placed.above);

    // Process's call. spk_solve reports the meter and the pack for this film
    // and paper, and writes nothing to the session -- which is why Process
    // zeroes the two shifts itself.
    char* before = nullptr;
    check(spk_get_params(e.session.get(), &before) == SPK_OK && before, "params before solve");
    const std::string beforeText(before);
    spk_string_free(before);
    char* out = nullptr;
    check(spk_solve(e.session.get(), "both", &out) == SPK_OK && out, std::string("solve: ") + spk_last_error(nullptr));
    const auto solved = parsed(out);
    spk_string_free(out);
    char* afterParams = nullptr;
    check(spk_get_params(e.session.get(), &afterParams) == SPK_OK && afterParams, "params after solve");
    check(beforeText == afterParams, "spk_solve changed the session");
    spk_string_free(afterParams);
    const Json& pack = solved.at("solved_params");
    check(pack.at("exposure_compensation_ev").is_number() && pack.at("c_filter_neutral").is_number() &&
          pack.at("m_filter_neutral").is_number() && pack.at("y_filter_neutral").is_number(), "solve's fields");
    for (const char* method : {"balanced", "center", "protect_highlights", "protect_shadows"})
        check(solved.at("exposure_ev_by_method").at(method).is_number(), std::string("solve's EV for ") + method);
    // The pack is the engine's table row for Portra 400 on Supra Endura.
    std::ifstream file(resources / "neutral_print_filters.json", std::ios::binary);
    std::stringstream textStream;
    textStream << file.rdbuf();
    const auto table = parsed(textStream.str());
    const Json& row = table.at("kodak_supra_endura").at("TH-KG3").at("kodak_portra_400");
    check(row.items().size() == 3 && pack.at("c_filter_neutral").as_double() == row.items()[0].as_double() &&
          pack.at("m_filter_neutral").as_double() == row.items()[1].as_double() &&
          pack.at("y_filter_neutral").as_double() == row.items()[2].as_double(), "the solved pack is not the table's");
    std::printf("ramp: Process's solve: metered %+.3f EV, pack C %.1f M %.1f Y %.1f\n",
                pack.at("exposure_compensation_ev").as_double(), pack.at("c_filter_neutral").as_double(),
                pack.at("m_filter_neutral").as_double(), pack.at("y_filter_neutral").as_double());
}

// --- the Tone Mask's curve ------------------------------------------------------

void tone_mask_curve() {
    // ToneMaskTests' calibration: an amount of N stops moves a base 4 stops
    // past the core by N, either way; the core is untouched.
    for (double core : {0.5, 1.0, 2.0})
        for (double amount : {0.25, 1.0, 2.0, 3.0}) {
            check(near(predev::toneMaskDelta(-core - 4.0, amount, 0, core), amount, 1e-12), "highlight calibration");
            check(near(predev::toneMaskDelta(core + 4.0, 0, amount, core), -amount, 1e-12), "shadow calibration");
            check(predev::toneMaskDelta(0.0, amount, amount, core) == 0.0 &&
                  predev::toneMaskDelta(-core * 0.99, amount, amount, core) == 0.0, "the core moved");
        }
    check(predev::toneMaskDelta(-5.0, 0, 3.0, 1.0) == 0.0 && predev::toneMaskDelta(5.0, 3.0, 0, 1.0) == 0.0,
          "an amount acted on the other side");
    check(std::abs(predev::toneMaskDelta(-40.0, 3.0, 0, 1.0)) < 6.0, "the gain bound");
}

// --- white balance rules --------------------------------------------------------

void white_balance_rules() {
    const predev::AsShot camera{5411.7, 15.45};
    desktop::WhiteBalance shot;  // As Shot, its numbers stale (the defaults)
    auto b = predev::boxes(shot, camera);
    check(b.temperature && b.tint, "As Shot does not tick both boxes");
    check(!predev::boxes(shot, std::nullopt).temperature, "boxes ticked with no camera pair");
    // Unticking Temperature keeps the picture: Custom at the camera's pair,
    // its tint still the camera's, so the Tint box stays ticked.
    auto t = predev::applyingBoxes(shot, false, std::nullopt, camera);
    check(t.mode == "custom" && t.temperature == 5411.7 && t.tint == 15.45, "unticking Temperature moved the picture");
    b = predev::boxes(t, camera);
    check(b.tint && b.temperature, "Custom at the camera's pair is not read as the camera's");
    // A slider leaves As Shot at the camera's other axis.
    auto warm = predev::withTemperature(shot, 3200, camera);
    check(warm.mode == "custom" && warm.temperature == 3200 && warm.tint == 15.45, "a temperature drag from As Shot");
    b = predev::boxes(warm, camera);
    check(!b.temperature && b.tint, "the boxes after a temperature drag");
    // Ticking Temperature again pins it; both ticked is As Shot.
    auto pinned = predev::applyingBoxes(warm, true, std::nullopt, camera);
    check(pinned.mode == "as_shot" && pinned.temperature == 5411.7, "ticking Temperature with Tint ticked");
    auto tinted = predev::withTint(warm, -20, camera);
    check(tinted.mode == "custom" && tinted.tint == -20 && tinted.temperature == 3200, "a tint drag");
    pinned = predev::applyingBoxes(tinted, std::nullopt, true, camera);
    check(pinned.mode == "custom" && pinned.tint == 15.45 && pinned.temperature == 3200, "ticking Tint alone");
    // Presets: their Kelvin at tint 0; As Shot the camera's pair; nothing else.
    auto daylight = predev::withPreset(tinted, "daylight", camera);
    check(daylight && daylight->mode == "daylight" && daylight->temperature == 5500 && daylight->tint == 0, "Daylight");
    b = predev::boxes(*daylight, camera);
    check(!b.temperature && !b.tint, "a preset ticked a box");
    auto back = predev::withPreset(*daylight, "as_shot", camera);
    check(back && back->as_shot() && back->temperature == 5411.7 && back->tint == 15.45, "As Shot preset");
    check(!predev::withPreset(shot, "custom", camera) && !predev::withPreset(shot, "candlelight", camera),
          "Custom or an unknown name offered as a preset");
    // Without a camera pair the boxes change nothing.
    check(predev::applyingBoxes(warm, true, true, std::nullopt).mode == "custom", "boxes without a camera pair");
    // A camera pair outside the rows is held to them.
    auto hot = predev::withTint(desktop::WhiteBalance{}, 10, predev::AsShot{60000, 200});
    check(hot.temperature == 50000 && hot.tint == 10, "an out-of-range camera pair escaped the rows");
}

// --- the eyedropper's geometry ----------------------------------------------------

void eyedropper_geometry() {
    // Each source pixel holds its own coordinates (x * 1000, y * 1000), so a
    // pixel of any rendered geometry -- interpolated or not -- names the
    // source point it shows.
    constexpr int W = 40, H = 30;
    QImage source(W, H, QImage::Format_RGBA64);
    for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x) source.setPixelColor(x, y, QColor::fromRgba64(quint16(x * 1000), quint16(y * 1000), 0, 65535));
    std::vector<spk::desktop::output::Geometry> cases;
    cases.push_back({});
    cases.push_back({QRectF(0.1, 0.2, 0.5, 0.6)});
    for (int turns = 1; turns < 4; ++turns) cases.push_back({QRectF(0.1, 0.2, 0.5, 0.6), turns});
    cases.push_back({QRectF(0, 0, 1, 1), 0, true, false});
    cases.push_back({QRectF(0.05, 0.1, 0.8, 0.7), 1, true, true});
    cases.push_back({QRectF(0.05, 0.1, 0.8, 0.7), 3, false, true});
    cases.push_back({QRectF(0.1, 0.1, 0.8, 0.8), 0, false, false, 7.5});
    cases.push_back({QRectF(0.1, 0.15, 0.7, 0.75), 1, true, false, -12.0});
    int points = 0;
    double worst = 0;
    for (const auto& g : cases) {
        const QImage shown = spk::desktop::output::displayImage(source, g);
        for (int y = 0; y < shown.height(); y += 3)
            for (int x = 0; x < shown.width(); x += 3) {
                const auto p = predev::sourcePoint(QSize(W, H), g, QPointF((x + 0.5) / shown.width(), (y + 0.5) / shown.height()));
                check(bool(p), "a point inside the picture was refused");
                const QRgba64 c = shown.pixelColor(x, y).rgba64();
                const double sx = (c.red() / 1000.0 + 0.5) / W, sy = (c.green() / 1000.0 + 0.5) / H;
                worst = std::max({worst, std::abs(p->x() - sx) * W, std::abs(p->y() - sy) * H});
                ++points;
            }
    }
    std::printf("eyedropper: %d points over %zu geometries, worst %.4f source pixels from what FrameOutput shows\n",
                points, cases.size(), worst);
    check(worst < 0.01, "the eyedropper does not land where the canvas shows");
    check(!predev::sourcePoint(QSize(W, H), {}, QPointF(1.2, 0.5)) && !predev::sourcePoint(QSize(W, H), {QRectF(0, 0, 0, 1)}, QPointF(0.5, 0.5)),
          "a point outside the picture or a broken crop was mapped");
}

// --- the controller, no photograph -------------------------------------------------

void controller_api(const std::filesystem::path& resources, const QString& scratch) {
    PreviewController c(resources, nullptr, {}, QDir(scratch).absoluteFilePath("edits"));
    {
        QEventLoop wait;
        QObject::connect(&c, &PreviewController::initialized, &wait, &QEventLoop::quit);
        QTimer::singleShot(60000, &wait, &QEventLoop::quit);
        if (!c.ready() && !c.failed()) wait.exec();
    }
    check(c.ready(), "engine initialization: " + c.status().toStdString());
    auto wb = c.whiteBalance();
    check(wb.value("mode") == "as_shot" && wb.value("temperature").toDouble() == 5500 && !wb.value("asShotKnown").toBool() &&
          !wb.value("boxesEnabled").toBool() && wb.value("enabled").toBool() && wb.value("temperatureFrom").toDouble() == 2000 &&
          wb.value("temperatureTo").toDouble() == 12000 && wb.value("temperatureZero").toDouble() == 5500 &&
          !wb.value("pickAvailable").toBool(), "white balance with no photograph");
    QStringList ids;
    for (const auto& preset : c.whiteBalancePresets()) ids.append(preset.toMap().value("id").toString());
    check(ids == QStringList{"as_shot", "daylight", "cloudy", "shade", "tungsten", "fluorescent"}, "presets");
    check(c.setWhiteBalancePreset("tungsten") && c.parameter("white_balance") == "tungsten" &&
          c.parameter("white_balance_temperature").toDouble() == 3200 && c.parameter("white_balance_tint").toDouble() == 0,
          "Tungsten");
    check(c.setTemperature(4100) && c.whiteBalance().value("mode") == "custom" &&
          c.whiteBalance().value("temperature").toDouble() == 4100, "a temperature");
    check(c.setTint(-12) && c.parameter("white_balance_tint").toDouble() == -12, "a tint");
    check(!c.setTemperature(1999) && !c.setTint(150.5) && !c.setTemperature(std::nan("")) &&
          !c.setWhiteBalancePreset("candlelight") && !c.setWhiteBalancePreset("custom"), "refusals");
    check(!c.setTemperatureAsShot(true) && !c.setTintAsShot(true), "As Shot boxes with no camera pair");
    check(c.setWhiteBalancePreset("as_shot") && c.parameter("white_balance") == "as_shot", "As Shot");
    check(!c.pickNeutral(0.5, 0.5) && !c.process() && !c.canProcess(), "picker or Process with no photograph");
    check(!c.latitude().value("available").toBool() && !c.metering().value("available").toBool() &&
          !c.scenePlacement().value("enabled").toBool() && !c.placeScene(1, 0, "highlight"),
          "Latitude or Scene Placement with no measurement");
    // Scene Placement's rows and their reset.
    check(c.setParameter("scene_latitude_highlight_pull_back", 1.5) &&
          c.scenePlacement().value("highlight").toDouble() == 1.5, "a pull-back row");
    c.resetScenePlacement();
    check(c.parameter("scene_latitude_highlight_pull_back").toDouble() == 0 && !c.scenePlacement().value("active").toBool(),
          "Scene Placement reset");
    // The Tone Mask section's state, its curve and its reset.
    auto mask = c.toneMask();
    check(mask.value("allowed").toBool() && !mask.value("active").toBool() && !mask.value("rowsEnabled").toBool() &&
          mask.value("isDefault").toBool() && mask.value("curve").toList().size() == 121 &&
          near(mask.value("radiusPercent").toDouble(), 3.0, 1e-12) && near(mask.value("radiusFrom").toDouble(), 0.2, 1e-12) &&
          near(mask.value("radiusTo").toDouble(), 12.0, 1e-12), "the Tone Mask at its defaults");
    check(c.setParameter("contrast_mask_active", true) && c.setParameter("contrast_mask_highlights", 1.5), "mask edits");
    mask = c.toneMask();
    const auto point = mask.value("curve").toList()[10].toMap();  // x = -5
    check(mask.value("rowsEnabled").toBool() && !mask.value("isDefault").toBool() &&
          near(point.value("x").toDouble(), -5.0, 1e-12) &&
          near(point.value("y").toDouble(), predev::toneMaskDelta(-5.0, 1.5, 0, 1.0), 1e-12), "the mask's curve");
    check(c.setParameter("print_effects", false) && !c.toneMask().value("allowed").toBool() &&
          c.toneMask().value("reason") == "printEffectsOff" && !c.toneMask().value("rowsEnabled").toBool(),
          "Print Effects off greys the Tone Mask");
    c.resetToneMask();
    check(c.toneMask().value("isDefault").toBool() && c.parameter("print_effects") == false, "Tone Mask reset");
}
}  // namespace

int main(int argc, char** argv) {
    QCoreApplication application(argc, argv);
    try {
        const auto args = application.arguments();
        check(args.size() == 3, "usage: spk_qt_predev_test <resources> <scratch-directory>");
        check(QDir().mkpath(args[2]), "cannot create scratch directory");
        const std::filesystem::path resources(args[1].toStdWString());
        readout_rules();
        tone_mask_curve();
        white_balance_rules();
        eyedropper_geometry();
        engine_ramp(resources);
        controller_api(resources, args[2]);
        std::printf("Pre-Dev backend: %d checks passed; no RAW.\n", checks);
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "Pre-Dev backend FAILED after %d checks: %s\n", checks, error.what());
        return 1;
    }
}
