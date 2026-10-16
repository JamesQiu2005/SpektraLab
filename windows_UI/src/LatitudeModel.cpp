#include "LatitudeModel.hpp"
#include <QStringList>
#include <algorithm>
#include <cmath>
#include <cstdio>

namespace spk::desktop::predev {
namespace {

bool numbers(const Json& value, std::vector<double>& out) {
    if (!value.is_array()) return false;
    out.clear();
    for (const auto& item : value.items()) {
        if (!item.is_number()) return false;
        out.push_back(item.as_double());
    }
    return true;
}

slm::FitIssue issue(std::string code, Side side, std::string message = {}) {
    return {std::move(code), sideName(side), std::move(message)};
}

// `v` on the sliders' grid, as the nearest double to that hundredth
// (PlacementWindow.hundredth, Latitude.swift:162-164).
double hundredth(double v, bool up) {
    const double steps = v / PlacementWindow::grain;
    return (up ? std::ceil(steps) : std::floor(steps)) / std::round(1.0 / PlacementWindow::grain);
}

double minimumFor(const LatitudeReading& reading, Side side) {
    // PlacementFit.Measured.minimum (Latitude.swift:238-240), at the Fit's
    // default extremes P99.9 / P0.1 (slm::Extremes{}).
    return side == Side::highlight ? reading.p999 - reading.highlightEv : reading.shadowEv - reading.p01;
}

QString stops(double v) {
    // LatitudeSection.stops (:126-128): a real minus sign, two decimals.
    const QString sign = v > 0 ? QStringLiteral("+") : v < 0 ? QString(QChar(0x2212)) : QString();
    return sign + QString::number(std::abs(v), 'f', 2);
}

QVariantList list(const std::vector<double>& values) {
    QVariantList out;
    out.reserve(qsizetype(values.size()));
    for (double v : values) out.push_back(v);
    return out;
}

}  // namespace

const char* sideName(Side side) { return side == Side::highlight ? "highlight" : "shadow"; }

bool readLatitude(const Json& reply, LatitudeReading& out, std::string& error) {
    const Json& m = reply.at("medium");
    const Json& s = reply.at("scene");
    const Json& h = s.at("histogram");
    LatitudeReading r;
    if (!m.at("shadow_ev").is_number() || !m.at("highlight_ev").is_number() || !numbers(m.at("ramp_ev"), r.rampEv) ||
        !numbers(m.at("ramp_y"), r.rampY) || r.rampEv.size() != r.rampY.size() || !numbers(h.at("fractions"), r.fractions) ||
        r.fractions.size() != std::size_t(slm::SceneStats::kBins) || !s.at("p0_1").is_number() ||
        !s.at("p99_9").is_number()) {
        error = "scene latitude: the reply is not a measurement";
        return false;
    }
    r.shadowEv = m.at("shadow_ev").as_double();
    r.highlightEv = m.at("highlight_ev").as_double();
    r.yBlack = m.at("y_black").as_double();
    r.yWhite = m.at("y_white").as_double();
    r.p01 = s.at("p0_1").as_double();
    r.p1 = s.at("p1").as_double();
    r.p50 = s.at("p50").as_double();
    r.p99 = s.at("p99").as_double();
    r.p999 = s.at("p99_9").as_double();
    r.loEv = h.at("lo_ev").as_double(slm::SceneStats::kLo);
    r.hiEv = h.at("hi_ev").as_double(slm::SceneStats::kHi);
    if (s.at("norm").is_string()) r.norm = s.at("norm").as_string();
    const Json& fit = reply.at("fit");
    r.fitValid = fit.at("valid").as_bool();
    for (const auto& item : fit.at("issues").items())
        r.fitIssues.push_back({item.at("code").as_string(), item.at("side").as_string(), item.at("message").as_string()});
    out = std::move(r);
    return true;
}

slm::Medium medium(const LatitudeReading& reading) {
    slm::Medium m;
    m.ev = reading.rampEv;
    m.y = reading.rampY;
    m.y_black = reading.yBlack;
    m.y_white = reading.yWhite;
    m.shadow_ev = reading.shadowEv;
    m.highlight_ev = reading.highlightEv;
    m.valid = true;
    return m;
}

slm::SceneStats scene(const LatitudeReading& reading) {
    slm::SceneStats s;
    s.p01 = reading.p01;
    s.p1 = reading.p1;
    s.p50 = reading.p50;
    s.p99 = reading.p99;
    s.p999 = reading.p999;
    s.histogram = reading.fractions;
    s.samples = reading.fractions.empty() ? 0 : 1;
    return s;
}

LatitudeReadout readout(const LatitudeReading& reading, const SceneLatitudeParams& placement) {
    LatitudeReadout out;
    // The curve renders only while active (the node dispatches nothing
    // otherwise); placed_histogram returns the input with both rooms at 0.
    out.fractions = placement.active ? slm::placed_histogram(scene(reading), placement) : reading.fractions;
    const auto n = std::max<std::size_t>(out.fractions.size(), 1);
    out.binWidth = (reading.hiEv - reading.loEv) / double(n);
    for (std::size_t i = 0; i < out.fractions.size(); ++i)
        out.centres.push_back(reading.loEv + (double(i) + 0.5) * out.binWidth);
    out.shadowEv = reading.shadowEv;
    out.highlightEv = reading.highlightEv;
    double total = 0;
    for (std::size_t i = 0; i < out.fractions.size(); ++i) {
        total += out.fractions[i];
        if (out.centres[i] < out.shadowEv) out.below += out.fractions[i];
        else if (out.centres[i] > out.highlightEv) out.above += out.fractions[i];
    }
    out.within = std::max(0.0, total - out.above - out.below);

    // CIE L* of the print against its own white, per ramp step.
    const double white = std::max(reading.yWhite, 1e-9);
    const auto lstar = [&](double y) {
        const double t = std::max(y, 0.0) / white;
        return t > 0.008856 ? 116.0 * std::cbrt(t) - 16.0 : 903.3 * t;
    };
    std::vector<std::pair<double, double>> slopes;
    for (std::size_t i = 0; i + 1 < reading.rampEv.size(); ++i) {
        const double e0 = reading.rampEv[i], e1 = reading.rampEv[i + 1];
        if (!(e1 > e0)) continue;
        slopes.emplace_back((e0 + e1) / 2.0,
                            std::max(0.0, (lstar(reading.rampY[i + 1]) - lstar(reading.rampY[i])) / (e1 - e0)));
    }
    double peak = 0;
    for (const auto& s : slopes) peak = std::max(peak, s.second);
    if (peak > 0)
        for (const auto& s : slopes) out.separation.emplace_back(s.first, s.second / peak);
    for (const auto& s : out.separation)
        if (s.second >= 0.5) {
            if (!out.core) out.core = std::make_pair(s.first, s.first);
            out.core->first = std::min(out.core->first, s.first);
            out.core->second = std::max(out.core->second, s.first);
        }
    return out;
}

slm::Fit fit(const LatitudeReading& reading, double highlight, double shadow, const SceneLatitudeParams& base) {
    return slm::fit(medium(reading), scene(reading), highlight, shadow, base);
}

SceneLatitudeParams committedCurve(const slm::Fit& f) {
    SceneLatitudeParams p = f.params;
    p.active = f.highlight.on || f.shadow.on;
    return p;
}

std::pair<double, std::optional<slm::FitIssue>> PlacementWindow::landing(double asked) const {
    if (!(asked > 0)) return {0.0, std::nullopt};
    if (!hasSpan) return {0.0, below};
    if (asked < least) return {least, below};
    if (asked > most) return {most, above};
    return {asked, std::nullopt};
}

PlacementWindow placementWindow(const LatitudeReading& reading, Side side, double other,
                                const SceneLatitudeParams& base) {
    // PlacementWindow.search (Latitude.swift:171-213), its verdict the Fit's.
    constexpr double step = 0.125;
    const auto verdict = [&](double x) -> std::optional<slm::FitIssue> {
        const slm::Fit f = fit(reading, side == Side::highlight ? x : other, side == Side::shadow ? x : other, base);
        if (f.valid()) return std::nullopt;
        return issue(f.issues.front().code, side, f.issues.front().message);
    };
    PlacementWindow w;
    w.below = issue("pull_back_below_minimum", side);
    double refusedAt = std::max({minimumFor(reading, side), placementLow, 0.0});
    std::optional<double> found;
    for (double x = std::floor(refusedAt / step) * step + step; x <= placementHigh + 1e-9; x += step) {
        if (const auto why = verdict(x)) {
            w.below = *why;
            refusedAt = x;
        } else {
            found = x;
            break;
        }
    }
    if (!found) {
        w.below = issue(PlacementWindow::noWindowCode, side, w.below.message);
        return w;
    }
    double bad = refusedAt, good = *found;
    while (good - bad > PlacementWindow::grain / 2) {
        const double mid = (bad + good) / 2;
        if (const auto why = verdict(mid)) {
            w.below = *why;
            bad = mid;
        } else {
            good = mid;
        }
    }
    w.hasSpan = true;
    w.least = std::min(hundredth(good, true), *found);
    w.most = placementHigh;
    if (const auto top = verdict(placementHigh)) {
        w.above = *top;
        good = *found;
        bad = placementHigh;
        while (bad - good > PlacementWindow::grain / 2) {
            const double mid = (bad + good) / 2;
            if (const auto why = verdict(mid)) {
                w.above = *why;
                bad = mid;
            } else {
                good = mid;
            }
        }
        w.most = std::max(hundredth(good, false), w.least);
    }
    return w;
}

std::optional<std::string> refusalMessage(const slm::FitIssue& refusal, Side side, double minimum) {
    if (refusal.side != sideName(side) && refusal.side != "both") return std::nullopt;
    const bool top = side == Side::highlight;
    const std::string part = top ? "brightest" : "darkest";
    if (refusal.code == "pull_back_below_minimum") {
        if (minimum > 0) {
            char n[32];
            std::snprintf(n, sizeof n, "%.2f", minimum);
            return "Pull back more than " + std::string(n) + " stops: any less still puts the scene's " + part +
                   " part past the latitude's edge.";
        }
        return "Pull back further: the scene's " + part + " part is still past the latitude's edge.";
    }
    if (refusal.code == "room_below_minimum")
        return std::string("Pull back a little more: this close to the latitude's edge the ") +
               (top ? "highlights" : "shadows") + " would turn too sharply.";
    if (refusal.code == PlacementWindow::noWindowCode)
        return top ? "This frame's highlights cannot be pulled inside the latitude: no pull-back works here."
                   : "This frame's shadows are too far under the latitude's edge to be lifted inside it.";
    if (refusal.code == "out_of_range") return "Pull back less: this is further than the curve can reach.";
    if (refusal.code == "pull_back_exceeds_max_lift") return "Pull back less: this is past the most the shadows can be lifted.";
    if (refusal.code == "knees_cross") return "The highlight and shadow curves would cross: pull back less on one side.";
    return refusal.message;
}

double toneMaskDelta(double base, double highlights, double shadows, double core) {
    constexpr double reach = 4.0, limit = 6.0;  // kReach, kGainLimit
    const auto room = [&](double amount) {
        const double delta = amount * limit / std::sqrt(limit * limit - amount * amount);
        const double t = std::max(reach - delta, 1e-3);
        return reach * t / std::sqrt(reach * reach - t * t);
    };
    double d = 0;
    if (highlights > 0 && base < -core) {
        const double D = -core - base, H = room(highlights);
        d = D - D * H / std::sqrt(H * H + D * D);
    } else if (shadows > 0 && base > core) {
        const double D = base - core, S = room(shadows);
        d = D * S / std::sqrt(S * S + D * D) - D;
    }
    return d * limit / std::sqrt(limit * limit + d * d);
}

QVariantMap latitudeVariant(const LatitudeReadout& r) {
    QVariantList separation;
    for (const auto& s : r.separation) separation.push_back(QVariantMap{{"ev", s.first}, {"strength", s.second}});
    // LatitudePlot's fixed -8..8 axis, and what falls past each end
    // (LatitudeSection.swift:26, :189-200).
    constexpr double axisFrom = -8.0, axisTo = 8.0;
    double under = 0, over = 0;
    for (std::size_t i = 0; i < r.centres.size(); ++i) {
        if (r.centres[i] < axisFrom) under += r.fractions[i];
        else if (r.centres[i] > axisTo) over += r.fractions[i];
    }
    QVariantMap out{{"centres", list(r.centres)}, {"fractions", list(r.fractions)}, {"binWidth", r.binWidth},
        {"shadowEv", r.shadowEv}, {"highlightEv", r.highlightEv}, {"heldStops", r.highlightEv - r.shadowEv},
        {"below", r.below}, {"within", r.within}, {"above", r.above}, {"separation", separation},
        {"hasCore", bool(r.core)}, {"coreFrom", r.core ? r.core->first : 0.0}, {"coreTo", r.core ? r.core->second : 0.0},
        {"axisFrom", axisFrom}, {"axisTo", axisTo}, {"under", under}, {"over", over},
        {"summary", latitudeSummary(r)}};
    return out;
}

QVariantMap issueVariant(const slm::FitIssue& issue) {
    return {{"code", QString::fromStdString(issue.code)}, {"side", QString::fromStdString(issue.side)},
            {"message", QString::fromStdString(issue.message)}};
}

QVariantMap windowVariant(const PlacementWindow& w) {
    QVariantMap out{{"hasSpan", w.hasSpan}, {"from", w.least}, {"to", w.most}, {"below", issueVariant(w.below)}};
    out.insert("above", w.above ? QVariant(issueVariant(*w.above)) : QVariant());
    return out;
}

QString latitudeSummary(const LatitudeReadout& r) {
    // Each part unbreakable, as macOS makes it (:121-124): a narrow rail
    // wraps only between them.
    const QChar nbsp(0x00A0);
    QStringList parts{QString::number(r.highlightEv - r.shadowEv, 'f', 2) + nbsp + QStringLiteral("stops held"),
                      stops(r.shadowEv) + nbsp + QChar(0x2013) + nbsp + stops(r.highlightEv)};
    if (r.core)
        parts.append(QStringLiteral("full separation") + nbsp + stops(r.core->first) + nbsp + QChar(0x2013) + nbsp +
                     stops(r.core->second));
    for (auto& part : parts) part.replace(QLatin1Char(' '), nbsp);
    return parts.join(QStringLiteral(" · "));
}

}  // namespace spk::desktop::predev
