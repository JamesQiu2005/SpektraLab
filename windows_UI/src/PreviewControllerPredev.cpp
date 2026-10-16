// PreviewController's Pre-Dev rail: what macOS's Latitude, Camera, Scene
// Placement and Tone Mask sections and its Process button need from the
// backend (Panels/Sections/LatitudeSection.swift, CameraSection.swift,
// ParameterSections.swift, Model/Latitude.swift, Session.swift). A file of
// its own so the rest of the controller is untouched but for two hooks: the
// worker loop calls analyse() after each job, and syncing a placement hands
// over its intent rather than its curve (pastedPlacement).
//
// Where the work is done:
//  - the white balance is three settings rows; the host re-decodes when they
//    change (desktop/raw_white_balance.hpp). Only the neutral picker's sample
//    needs the worker, and it goes through submit() like any job;
//  - Process is a job: spk_solve "both" on the frame shown, then the Y/M
//    shifts back to 0 (Session.solveFilterPack, :3921-3931);
//  - the meter and the latitude are measured after every job that leaves a
//    new frame on the session, once per frame, on the worker: spk_solve
//    "exposure" (what macOS runs after each develop, :2314-2329) and
//    spk_scene_latitude with the frame's own pull-backs (Latitude.swift
//    probeLatitude). Neither renders; both are cached engine-side on the
//    fields they read. The UI takes them only for the frame on screen;
//  - a Scene Placement slider step is solved here, on the last measurement,
//    by the engine's own Fit (core/latitude_fit.hpp) and committed in the
//    same call (Latitude.swift:427-461), as macOS does with its port of it.
#include "PreviewController.hpp"
#include "LatitudeModel.hpp"
#include "WhiteBalance.hpp"
#include <QMetaObject>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <map>

namespace {
namespace desktop = spk::desktop;
namespace predev = spk::desktop::predev;
using spk::Json;

QString qtext(const std::string& s) { return QString::fromUtf8(s.data(), qsizetype(s.size())); }
double number(const desktop::RenderSettings& s, const char* key) { return std::get<double>(s.get(key)); }
bool flag(const desktop::RenderSettings& s, const char* key) { return std::get<bool>(s.get(key)); }
double since(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
}

// The camera's own white balance for the frame on screen (on a half-frame
// pair, the camera frame's own decode: PreviewController::shotMetadata).
std::optional<predev::AsShot> cameraPair(const spk::io::RawMetadata* metadata) {
    double temperature = 0, tint = 0;
    if (!metadata || !desktop::as_shot_white_balance(*metadata, temperature, tint)) return std::nullopt;
    return predev::AsShot{temperature, tint};
}
// A camera LibRaw has no three-colour matrix for cannot be re-balanced.
bool balanceable(const spk::io::RawMetadata* metadata) { return !metadata || metadata->colors == 3; }

// The Scene Placement rows as the engine's curve, and back.
constexpr const char* curveRows[] = {"scene_latitude_active", "scene_latitude_norm", "scene_latitude_highlight_knee",
                                     "scene_latitude_highlight_room", "scene_latitude_shadow_knee",
                                     "scene_latitude_shadow_room", "scene_latitude_rolloff", "scene_latitude_max_lift"};
spk::SceneLatitudeParams curveOf(const desktop::RenderSettings& s) {
    spk::SceneLatitudeParams p;
    p.active = flag(s, "scene_latitude_active");
    p.norm = std::get<std::string>(s.get("scene_latitude_norm"));
    p.highlight_knee = number(s, "scene_latitude_highlight_knee");
    p.highlight_room = number(s, "scene_latitude_highlight_room");
    p.shadow_knee = number(s, "scene_latitude_shadow_knee");
    p.shadow_room = number(s, "scene_latitude_shadow_room");
    p.rolloff = number(s, "scene_latitude_rolloff");
    p.max_lift = number(s, "scene_latitude_max_lift");
    return p;
}
void setCurve(desktop::RenderSettings& s, const spk::SceneLatitudeParams& p) {
    s.set("scene_latitude_active", p.active);
    s.set("scene_latitude_norm", p.norm);
    s.set("scene_latitude_highlight_knee", p.highlight_knee);
    s.set("scene_latitude_highlight_room", p.highlight_room);
    s.set("scene_latitude_shadow_knee", p.shadow_knee);
    s.set("scene_latitude_shadow_room", p.shadow_room);
    s.set("scene_latitude_rolloff", p.rolloff);
    s.set("scene_latitude_max_lift", p.max_lift);
}
void resetRow(desktop::RenderSettings& s, const char* key) { s.set(key, desktop::find_setting(key)->initial); }

spk::slm::FitIssue issueOf(const QVariantMap& map) {
    return {map.value("code").toString().toStdString(), map.value("side").toString().toStdString(),
            map.value("message").toString().toStdString()};
}

// Whether a measurement taken on `measured` still describes `wanted`: the
// Fit reads the medium (film, paper, enlarger, Exp. Comp. -- the probe runs
// with the placement off, engine.cpp medium_probe_params) and the scene (the
// meter's frame, before the placement node, on the norm). The placement's
// own curve and UI state are read by neither, so a slider step keeps the
// last measurement good -- a drag must not wait for each re-develop -- while
// any other edit (an enlarger shift, a film, a white balance) makes it stale
// until the frame it renders is measured. A curve fitted to a stale medium
// is a placement for a different print: it lands the scene's extreme
// somewhere other than the slider says. The norm is the scene's, so it is
// compared.
bool measures(const desktop::RenderSettings& measured, desktop::RenderSettings wanted) {
    for (const char* key : {"scene_latitude_active", "scene_latitude_highlight_knee", "scene_latitude_highlight_room",
                            "scene_latitude_shadow_knee", "scene_latitude_shadow_room", "scene_latitude_rolloff",
                            "scene_latitude_max_lift", "scene_latitude_highlight_pull_back",
                            "scene_latitude_shadow_pull_back", "scene_latitude_needs_fit"})
        wanted.set(key, measured.get(key));
    // The brightness round-trips through stops in the controls.
    if (std::abs(wanted.print_exposure - measured.print_exposure) < 1e-12) wanted.print_exposure = measured.print_exposure;
    return wanted == measured;
}
}  // namespace

// One frame's readings, measured on the worker after the job that left it on
// the session.
struct PreviewController::Analysis {
    desktop::FramePtr frame;
    std::optional<double> meteredEv;          // the session's own intent
    std::map<std::string, double> byMethod;   // the four intents' EVs
    std::optional<predev::LatitudeReading> reading;
    std::string failure;                      // why there is no reading
    double solveMs = 0, latitudeMs = 0;
};

void PreviewController::analyse(desktop::PreviewHost& host) {
    const auto frame = host.current();
    spk_session* session = host.session();
    if (!frame || !session || analysed_.lock() == frame) return;
    analysed_ = frame;
    auto a = std::make_shared<Analysis>();
    a->frame = frame;
    // The meter: spk_solve "exposure" measures and reports without touching
    // the session (Session.swift:2316-2318).
    auto started = std::chrono::steady_clock::now();
    char* out = nullptr;
    if (spk_solve(session, "exposure", &out) == SPK_OK && out) {
        Json reply;
        std::string error;
        if (Json::parse(out, reply, error)) {
            const Json& ev = reply.at("solved_params").at("exposure_compensation_ev");
            if (ev.is_number()) a->meteredEv = ev.as_double();
            for (const auto& [method, value] : reply.at("exposure_ev_by_method").fields())
                if (value.is_number()) a->byMethod[method] = value.as_double();
        }
    }
    if (out) spk_string_free(out);
    a->solveMs = since(started);
    // The latitude, at the frame's own placement (Latitude.swift:542-548):
    // 0 is a side off, which is not the same as asking for the suggestion.
    started = std::chrono::steady_clock::now();
    Json request = Json::object();
    request.set("highlight_pull_back", Json(number(frame->settings, "scene_latitude_highlight_pull_back")));
    request.set("shadow_pull_back", Json(number(frame->settings, "scene_latitude_shadow_pull_back")));
    pairFitRequest(frame, request);  // a half-frame pair: the camera frame's hole and pull-backs
    out = nullptr;
    if (spk_scene_latitude(session, request.dump().c_str(), &out) == SPK_OK && out) {
        Json reply;
        std::string error;
        predev::LatitudeReading reading;
        if (Json::parse(out, reply, error) && predev::readLatitude(reply, reading, error)) a->reading = std::move(reading);
        else a->failure = error;
    } else {
        a->failure = spk_last_error(nullptr);
    }
    if (out) spk_string_free(out);
    a->latitudeMs = since(started);
    QMetaObject::invokeMethod(this, [this, a] { takeAnalysis(a); }, Qt::QueuedConnection);
}

void PreviewController::takeAnalysis(std::shared_ptr<const Analysis> a) {
    // Only for the frame on screen: a superseded render's, a batch export's
    // or another photograph's readings never reach the rail.
    if (!a || !frame_ || a->frame != frame_) return;
    if (!analysis_ || analysis_->frame->source != a->frame->source) refusal_.clear();
    analysis_ = std::move(a);
    resolvePendingPlacement();
    emit settingsChanged();
}

// --- white balance -----------------------------------------------------------

QVariantMap PreviewController::whiteBalance() const {
    const auto value = desktop::white_balance(extra_settings_);
    const auto camera = cameraPair(shotMetadata());
    const auto ticked = predev::boxes(value, camera);
    const bool following = value.as_shot() && camera;
    QVariantMap out{{"mode", qtext(value.mode)},
        {"temperature", following ? camera->temperature : value.temperature},
        {"tint", following ? camera->tint : value.tint},
        {"temperatureAsShot", ticked.temperature}, {"tintAsShot", ticked.tint},
        {"asShotKnown", bool(camera)}, {"boxesEnabled", bool(camera)},
        {"asShotTemperature", camera ? QVariant(camera->temperature) : QVariant()},
        {"asShotTint", camera ? QVariant(camera->tint) : QVariant()},
        {"enabled", balanceable(shotMetadata())},
        // macOS's sliders (WhiteBalanceRows.swift:40-56): their ranges and
        // zero ticks; the rows themselves take 2000..50000 K.
        {"temperatureFrom", 2000.0}, {"temperatureTo", 12000.0}, {"tintFrom", -150.0}, {"tintTo", 150.0},
        {"temperatureZero", camera ? camera->temperature : 5500.0}, {"tintZero", camera ? camera->tint : 0.0},
        {"pickAvailable", bool(frame_) && !frame_->pair && balanceable(shotMetadata()) && ready_ && !busy_ && !dialog_open_}};
    return out;
}

QVariantList PreviewController::whiteBalancePresets() const {
    QVariantList out;
    for (const auto& preset : desktop::white_balance_presets())
        out.push_back(QVariantMap{{"id", QLatin1String(preset.id)}, {"label", QLatin1String(preset.label)},
                                  {"kelvin", preset.kelvin}});
    return out;
}

bool PreviewController::editWhiteBalance(const desktop::WhiteBalance& value, const QString& editKey) {
    if (!settingsEditable() || !balanceable(shotMetadata())) return false;
    auto next = extra_settings_;
    try {
        desktop::set_white_balance(next, value);
    } catch (const std::exception&) {
        return false;
    }
    for (const char* key : {"white_balance_temperature", "white_balance_tint"})
        if (!desktop::check_setting(*desktop::find_setting(key), next.get(key)).empty()) return false;
    if (next != extra_settings_) {
        extra_settings_ = std::move(next);
        changed(editKey);
    }
    return true;
}

bool PreviewController::setWhiteBalancePreset(const QString& id) {
    const auto next = predev::withPreset(desktop::white_balance(extra_settings_), id.toStdString(), cameraPair(shotMetadata()));
    return next && editWhiteBalance(*next, QStringLiteral("white_balance"));
}
bool PreviewController::setTemperature(double kelvin) {
    return editWhiteBalance(predev::withTemperature(desktop::white_balance(extra_settings_), kelvin, cameraPair(shotMetadata())),
                            QStringLiteral("white_balance_temperature"));
}
bool PreviewController::setTint(double tint) {
    return editWhiteBalance(predev::withTint(desktop::white_balance(extra_settings_), tint, cameraPair(shotMetadata())),
                            QStringLiteral("white_balance_tint"));
}
bool PreviewController::setTemperatureAsShot(bool on) {
    const auto camera = cameraPair(shotMetadata());
    return camera && editWhiteBalance(predev::applyingBoxes(desktop::white_balance(extra_settings_), on, std::nullopt,
                                                            camera), QStringLiteral("white_balance"));
}
bool PreviewController::setTintAsShot(bool on) {
    const auto camera = cameraPair(shotMetadata());
    return camera && editWhiteBalance(predev::applyingBoxes(desktop::white_balance(extra_settings_), std::nullopt, on,
                                                            camera), QStringLiteral("white_balance"));
}

bool PreviewController::pickNeutral(double x, double y) {
    // Not on a half-frame pair: its piece is two decodes (not ported).
    if (!ready_ || !frame_ || busy_ || dialog_open_ || frame_->metadata.colors != 3 || frame_->pair) return false;
    // A cut frame (Film Edge, a date on a cropped frame) shows the picture
    // the engine was handed, inside the strip, with its geometry already in
    // it: the point is found in that picture, then in the decode through
    // the geometry the frame was cut with.
    std::optional<QPointF> point;
    if (frame_->cut) {
        const auto picture = cutPictureRect();
        const QPointF at((x * frame_->width() - picture.x()) / picture.width(),
                         (y * frame_->height() - picture.y()) / picture.height());
        if (at.x() < 0 || at.y() < 0 || at.x() > 1 || at.y() > 1) return false;
        const auto& c = frame_->geometry;
        point = predev::sourcePoint(QSize(int(frame_->decode_width), int(frame_->decode_height)),
                                    {QRectF(c.x, c.y, c.w, c.h), c.quarter_turns, c.flip_h, c.flip_v, c.straighten_deg}, at);
    } else {
        point = predev::sourcePoint(QSize(int(frame_->width()), int(frame_->height())), geometry_, QPointF(x, y));
    }
    if (!point) return false;
    const auto shown = frame_;
    const auto gen = ++generation_;
    submit([this, shown, gen, p = *point](desktop::PreviewHost& host) {
        Reply r;
        r.generation = gen;
        r.operation = "pick-neutral";
        double kelvin = 0, tint = 0;
        std::string error;
        // The decode on the worker must be the one the frame on screen came
        // from: the picker reads scene values, not the print.
        const auto active = host.current();
        if (!active || active->source != shown->source || active->decode_mode != shown->decode_mode ||
            !desktop::same_decode(active->settings, shown->settings)) {
            error = "The photograph changed before the pick; pick again";
        } else {
            std::array<double, 3> rgb{};
            if (desktop::sample_decoded(host.input(), p.x(), p.y(), 4, rgb, error))
                desktop::neutral_white_balance(active->metadata, rgb, kelvin, tint, error);
        }
        // A refusal is the picker's answer, not a failed render: it is
        // reported apart (neutralPicked), and the controls are left alone.
        QMetaObject::invokeMethod(this, [this, shown, kelvin, tint, message = qtext(error)] {
            takeNeutral(shown, kelvin, tint, message);
        }, Qt::QueuedConnection);
        return r;
    }, uiText("status.rendering"), "pick-neutral");
    return true;
}

void PreviewController::takeNeutral(desktop::FramePtr shown, double kelvin, double tint, QString error) {
    if (shown != frame_ && error.isEmpty()) error = QStringLiteral("The photograph changed before the pick; pick again");
    if (!error.isEmpty()) {
        status_ = error;
        emit stateChanged();
        emit neutralPicked(false, error);
        return;
    }
    // Session.pickNeutral (:2827-2829): Custom at the answer, which the rows
    // take within their range. Applied during the pick's own job, so not
    // through the settings lock; one undo step, and the RAW re-decodes.
    auto next = extra_settings_;
    const auto* t = desktop::find_setting("white_balance_temperature");
    const auto* n = desktop::find_setting("white_balance_tint");
    desktop::set_white_balance(next, {"custom", std::clamp(kelvin, t->low, t->high), std::clamp(tint, n->low, n->high)});
    if (next != extra_settings_) {
        extra_settings_ = std::move(next);
        changed(QStringLiteral("white_balance"));
    }
    emit neutralPicked(true, QString());
}

// --- Process -----------------------------------------------------------------

bool PreviewController::canProcess() const { return ready_ && frame_ && !busy_ && !dialog_open_; }

bool PreviewController::process() {
    if (!canProcess()) return false;
    const auto shown = frame_;
    const auto gen = ++generation_;
    submit([this, shown, gen](desktop::PreviewHost& host) {
        Reply r;
        r.generation = gen;
        r.operation = "process";
        std::string reply, error;
        auto active = host.current();
        try {
            // macOS: on a frame not yet in the engine, Process is also the
            // develop (Session.swift:3896-3898). After a failed edit the
            // session is rebuilt from the frame on screen, and published.
            if (!active || active->source != shown->source || active->decode_mode != shown->decode_mode ||
                !host.session()) {
                // As the frame on screen was made: whole, or cut by its geometry.
                r.frame = host.open_raw(shown->source, shown->decode_mode, shown->settings, shown->geometry);
                active = r.frame;
            }
        } catch (const std::exception& e) {
            r.error = qtext(e.what());
            return r;
        }
        char* out = nullptr;
        if (spk_solve(host.session(), "both", &out) == SPK_OK && out) reply = out;
        else error = std::string("Process: ") + spk_last_error(nullptr);
        if (out) spk_string_free(out);
        QMetaObject::invokeMethod(this, [this, active, reply, message = qtext(error)] {
            takeSolve(active, reply, message);
        }, Qt::QueuedConnection);
        return r;
    }, uiText("status.rendering"), "process");
    return true;
}

void PreviewController::takeSolve(desktop::FramePtr frame, std::string reply, QString error) {
    Json parsed;
    std::string parseError;
    if (error.isEmpty() && !Json::parse(reply, parsed, parseError)) error = qtext("Process: " + parseError);
    if (!error.isEmpty()) {
        status_ = error;
        emit stateChanged();
        emit processed(false, error);
        return;
    }
    const Json& solved = parsed.at("solved_params");
    QVariantMap byMethod;
    for (const auto& [method, value] : parsed.at("exposure_ev_by_method").fields())
        byMethod.insert(qtext(method), value.as_double());
    filters_ = {{"c", solved.at("c_filter_neutral").as_double()}, {"m", solved.at("m_filter_neutral").as_double()},
                {"y", solved.at("y_filter_neutral").as_double()},
                {"exposureEv", solved.at("exposure_compensation_ev").as_double()}, {"byMethod", byMethod},
                {"source", QString::fromStdWString(frame->source.wstring())},
                {"film", qtext(frame->settings.film_stock)}, {"paper", qtext(frame->settings.print_stock)}};
    // The Y/M shifts are offsets from the solved neutrals, so they go back to
    // 0: a shift left on a freshly solved pack means Process visibly did not
    // solve (Session.swift:3913-3931). One undo step; the reprint follows.
    auto next = extra_settings_;
    next.y_filter_shift = 0;
    next.m_filter_shift = 0;
    if (next != extra_settings_) {
        extra_settings_ = std::move(next);
        changed(QStringLiteral("process"));
    } else {
        // Shifts already at 0: no reprint follows, so nothing else would
        // replace the "Updating the film look" line the submit put up.
        status_ = uiText("status.previewCurrent");
        emit stateChanged();
    }
    emit processed(true, QString());
    emit settingsChanged();
}

QVariantMap PreviewController::metering() const {
    if (auto pair = pairMetering()) return *pair;  // a half-frame pair: the camera frame's own meter
    QVariantMap out{{"available", false}};
    if (!frame_ || !analysis_ || analysis_->frame->source != frame_->source || !analysis_->meteredEv) return out;
    QVariantMap byMethod;
    for (const auto& [method, value] : analysis_->byMethod) byMethod.insert(qtext(method), value);
    out = {{"available", true}, {"exposureEv", *analysis_->meteredEv},
           // Session.solvedEVLabel (:3396-3399).
           {"label", QStringLiteral("auto %1 EV").arg(QString::asprintf("%+.1f", *analysis_->meteredEv))},
           {"byMethod", byMethod}, {"solveMs", analysis_->solveMs}};
    // Process's pack, while the photograph, film and paper it was solved for
    // are the ones shown.
    if (filters_.value("source").toString() == QString::fromStdWString(frame_->source.wstring()) &&
        filters_.value("film").toString() == qtext(settings().film_stock) &&
        filters_.value("paper").toString() == qtext(settings().print_stock))
        out.insert("filters", QVariantMap{{"c", filters_.value("c")}, {"m", filters_.value("m")}, {"y", filters_.value("y")}});
    return out;
}

// --- Latitude and Scene Placement --------------------------------------------

QVariantMap PreviewController::latitude() const {
    QVariantMap out{{"available", false}, {"failure", QString()}, {"failureKind", QString()}};
    // macOS keeps the last probe of the photograph while a newer one is on
    // its way, so the graph does not blink on every edit (Latitude.swift:34-37).
    if (!frame_ || !analysis_ || analysis_->frame->source != frame_->source) return out;
    if (!analysis_->reading) {
        // The engine's two expected refusals get their own kind, so the
        // QML can say them plainly (Latitude.swift:564-570).
        const auto& why = analysis_->failure;
        out["failure"] = qtext(why);
        out["failureKind"] = why.find("boundaries do not lie inside") != std::string::npos ? "unmeasurable"
                           : why.find("no positive pixels") != std::string::npos ? "noLight" : "other";
        return out;
    }
    const auto current = settings();
    // The committed curve of the controls, not of the reply: what the
    // render does with this placement, and at once when a slider moves.
    out = predev::latitudeVariant(predev::readout(*analysis_->reading, curveOf(current)));
    out.insert("available", true);
    out.insert("failure", QString());
    out.insert("failureKind", QString());
    out.insert("film", qtext(current.film_stock));
    out.insert("paper", qtext(current.print_stock));
    out.insert("scanned", noPrintProfile());
    out.insert("analysisMs", analysis_->latitudeMs);
    out.insert("current", analysis_->frame == frame_);
    return out;
}

QVariantMap PreviewController::scenePlacement() const {
    const auto current = settings();
    const double highlight = number(current, "scene_latitude_highlight_pull_back");
    const double shadow = number(current, "scene_latitude_shadow_pull_back");
    // Enabled on a measurement that still describes the controls (measures).
    const bool measured = frame_ && analysis_ && analysis_->frame->source == frame_->source && analysis_->reading &&
                          measures(analysis_->frame->settings, measurable(current));
    QVariantMap out{{"enabled", measured}, {"active", flag(current, "scene_latitude_active")},
        {"highlight", highlight}, {"shadow", shadow}, {"from", predev::placementLow}, {"to", predev::placementHigh},
        {"highlightWindow", QVariant()}, {"shadowWindow", QVariant()}, {"highlightMessage", QString()},
        {"shadowMessage", QString()}, {"refusal", refusal_.isEmpty() ? QVariant() : QVariant(refusal_)}};
    if (!measured) return out;
    const auto& reading = *analysis_->reading;
    const auto base = curveOf(current);
    for (const auto side : {predev::Side::highlight, predev::Side::shadow}) {
        const bool top = side == predev::Side::highlight;
        const auto window = predev::placementWindow(reading, side, top ? shadow : highlight, base);
        const double minimum = top ? reading.p999 - reading.highlightEv : reading.shadowEv - reading.p01;
        // A side with nothing the Fit takes says why without being touched
        // (ParameterSections.swift:247-251).
        std::optional<std::string> message;
        if (!refusal_.isEmpty()) message = predev::refusalMessage(issueOf(refusal_), side, minimum);
        if (!message && !window.hasSpan) message = predev::refusalMessage(window.below, side, minimum);
        out.insert(top ? "highlightWindow" : "shadowWindow", predev::windowVariant(window));
        out.insert(top ? "highlightMessage" : "shadowMessage", message ? qtext(*message) : QString());
    }
    return out;
}

bool PreviewController::placeScene(double highlight, double shadow, const QString& moving) {
    if (!settingsEditable() || !frame_ || !analysis_ || analysis_->frame->source != frame_->source ||
        !analysis_->reading || !std::isfinite(highlight) || !std::isfinite(shadow) ||
        (moving != QLatin1String("highlight") && moving != QLatin1String("shadow")))
        return false;
    const auto current = settings();
    // Solved only against a measurement of these controls; a stale one would
    // commit a curve for another medium (measures). The next measurement
    // lands with the render already on its way.
    if (!measures(analysis_->frame->settings, measurable(current))) return false;
    const auto side = moving == QLatin1String("shadow") ? predev::Side::shadow : predev::Side::highlight;
    const auto& reading = *analysis_->reading;
    const auto base = curveOf(current);
    double h = std::max(0.0, highlight), s = std::max(0.0, shadow);
    // The moving slider's value is brought inside the window the Fit takes,
    // so a drag across a refused stretch rides its edge (Latitude.swift:438-442).
    double& asked = side == predev::Side::shadow ? s : h;
    const auto landed = predev::placementWindow(reading, side, side == predev::Side::shadow ? h : s, base).landing(asked);
    asked = landed.first;
    const QVariantMap why = landed.second ? predev::issueVariant(*landed.second) : QVariantMap();
    auto next = extra_settings_;
    if (h == 0 && s == 0) {
        // Both sides off is the reset, which is not a Fit (:443-448).
        if (flag(current, "scene_latitude_active") || number(current, "scene_latitude_highlight_pull_back") > 0 ||
            number(current, "scene_latitude_shadow_pull_back") > 0) {
            for (const char* key : curveRows) resetRow(next, key);
            resetRow(next, "scene_latitude_highlight_pull_back");
            resetRow(next, "scene_latitude_shadow_pull_back");
            resetRow(next, "scene_latitude_needs_fit");
        }
    } else {
        const auto solved = predev::fit(reading, h, s, base);
        if (!solved.valid()) {
            // The side that is not moving no longer fits (the film changed
            // under it): nothing is committed, and the row says so.
            refusal_ = predev::issueVariant(solved.issues.front());
            emit settingsChanged();
            return false;
        }
        setCurve(next, predev::committedCurve(solved));
        next.set("scene_latitude_highlight_pull_back", h);
        next.set("scene_latitude_shadow_pull_back", s);
        next.set("scene_latitude_needs_fit", false);
    }
    refusal_ = why;
    if (next != extra_settings_) {
        extra_settings_ = std::move(next);
        changed(QStringLiteral("scene_placement"));
    } else {
        emit settingsChanged();
    }
    return true;
}

void PreviewController::resetScenePlacement() {
    if (!settingsEditable()) return;
    // SceneLatitudeSettings() whole (Session.resetScenePlacement, Latitude.swift:499-505).
    auto next = extra_settings_;
    for (const auto& field : desktop::setting_fields())
        if (field.key.rfind("scene_latitude_", 0) == 0) next.set(field.key, field.initial);
    refusal_.clear();
    if (next != extra_settings_) {
        extra_settings_ = std::move(next);
        changed(QStringLiteral("scene_placement"));
    } else {
        emit settingsChanged();
    }
}

desktop::RenderSettings PreviewController::pastedPlacement(desktop::RenderSettings s) {
    // The intent and the Fit's inputs travel; the curve stays the identity
    // until the recipient's own Fit lands (SettingsClipboard.swift:171-185).
    for (const char* key : {"scene_latitude_active", "scene_latitude_highlight_knee", "scene_latitude_highlight_room",
                            "scene_latitude_shadow_knee", "scene_latitude_shadow_room"})
        resetRow(s, key);
    s.set("scene_latitude_needs_fit", number(s, "scene_latitude_highlight_pull_back") > 0 ||
                                      number(s, "scene_latitude_shadow_pull_back") > 0);
    return s;
}

void PreviewController::resolvePendingPlacement() {
    // Session.resolvePendingPlacement (Latitude.swift:516-538): only once
    // the engine holds every pasted field -- the frame on screen is the
    // settings wanted -- because the Fit reads the medium and the scene the
    // session holds, and fitting against an older film is the defect this
    // replaces. A refusal leaves the placement off, with the reason.
    if (!flag(extra_settings_, "scene_latitude_needs_fit") || !analysis_ || analysis_->frame != frame_ ||
        !analysis_->reading || dirty() || busy_)
        return;
    const auto current = settings();
    auto next = extra_settings_;
    const auto solved = predev::fit(*analysis_->reading, number(current, "scene_latitude_highlight_pull_back"),
                                    number(current, "scene_latitude_shadow_pull_back"), curveOf(current));
    if (solved.valid()) {
        setCurve(next, predev::committedCurve(solved));
        refusal_.clear();
    } else {
        refusal_ = predev::issueVariant(solved.issues.front());
        next.set("scene_latitude_highlight_pull_back", 0.0);
        next.set("scene_latitude_shadow_pull_back", 0.0);
    }
    next.set("scene_latitude_needs_fit", false);
    // It completes the paste rather than being an edit of its own
    // (Session.finishPastedPlacement, :3833-3839): no undo step.
    extra_settings_ = std::move(next);
    saveActiveSettings();
    ++settings_revision_;
    auto_apply_.stop();
    schedulePreview();
    status_ = uiText("status.updatingPreview");
    emit settingsChanged();
    emit stateChanged();
}

// --- Tone Mask -----------------------------------------------------------------

QVariantMap PreviewController::toneMask() const {
    const auto current = settings();
    const bool allowed = flag(current, "print_effects");
    const bool active = flag(current, "contrast_mask_active");
    const double highlights = number(current, "contrast_mask_highlights");
    const double shadows = number(current, "contrast_mask_shadows");
    const double core = number(current, "contrast_mask_core");
    const double scale = number(current, "contrast_mask_scale");
    // ToneMaskPlot (ParameterSections.swift:327-353): x -6..6, y -3..3, 121 points.
    QVariantList curve;
    for (int i = 0; i <= 120; ++i) {
        const double x = -6.0 + 12.0 * i / 120.0;
        curve.push_back(QVariantMap{{"x", x}, {"y", std::clamp(predev::toneMaskDelta(x, highlights, shadows, core), -3.0, 3.0)}});
    }
    bool isDefault = true;
    for (const auto& field : desktop::setting_fields())
        if (field.key.rfind("contrast_mask_", 0) == 0 && current.get(field.key) != field.initial) isDefault = false;
    const auto* range = desktop::find_setting("contrast_mask_scale");
    return {{"allowed", allowed}, {"reason", allowed ? QString() : QStringLiteral("printEffectsOff")},
            {"active", active}, {"rowsEnabled", allowed && active}, {"highlights", highlights},
            {"shadows", shadows}, {"core", core}, {"scale", scale}, {"radiusPercent", scale * 100.0},
            {"radiusFrom", range->low * 100.0}, {"radiusTo", range->high * 100.0}, {"curve", curve},
            {"isDefault", isDefault}};
}

void PreviewController::resetToneMask() {
    if (!settingsEditable()) return;
    // ContrastMaskSettings() whole (ParameterSections.swift:282-286).
    auto next = extra_settings_;
    for (const auto& field : desktop::setting_fields())
        if (field.key.rfind("contrast_mask_", 0) == 0) next.set(field.key, field.initial);
    if (next != extra_settings_) {
        extra_settings_ = std::move(next);
        changed(QStringLiteral("contrast_mask"));
    }
}
