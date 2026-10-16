#pragma once
// The Pre-Dev rail's measurements: what macOS's Latitude section draws and
// what its Scene Placement sliders commit (Model/Latitude.swift,
// Panels/Sections/LatitudeSection.swift, ParameterSections.swift), read off
// one spk_scene_latitude reply (API-SPEC §12), plus the Tone Mask's curve
// (Model/ToneMask.swift). No Qt in the arithmetic; the QVariant views are
// what PreviewController hands QML.
//
// macOS transcribes the engine's Fit into Swift so a slider step need not
// wait for the engine (PlacementFit, held to the engine by
// ScenePlacementTests). Here the engine's own code is linked in:
// core/latitude_fit.hpp's fit() and placed_histogram() run on the four
// numbers and the histogram a measurement carries, so there is no second
// copy to keep in step.
#include "core/json.hpp"
#include "core/latitude_fit.hpp"
#include <QVariantList>
#include <QVariantMap>
#include <optional>
#include <string>
#include <vector>

namespace spk::desktop::predev {

// One spk_scene_latitude reply, as read.
struct LatitudeReading {
    // The medium: ISO 6846's boundaries on the session's own film and paper,
    // and the 128-point neutral ramp they were read from.
    double shadowEv = 0, highlightEv = 0, yBlack = 0, yWhite = 0;
    std::vector<double> rampEv, rampY;
    // The scene on the node's own axis (stops from the metered mid-grey).
    double p01 = 0, p1 = 0, p50 = 0, p99 = 0, p999 = 0;
    double loEv = slm::SceneStats::kLo, hiEv = slm::SceneStats::kHi;
    std::vector<double> fractions;
    std::string norm = "power";
    // What the engine answered for the pull-backs the request carried.
    bool fitValid = false;
    std::vector<slm::FitIssue> fitIssues;
};
// False, with `error`, for a reply that is not one.
bool readLatitude(const Json& reply, LatitudeReading& out, std::string& error);
// What the Fit reads: the reading's medium boundaries and scene statistic.
slm::Medium medium(const LatitudeReading& reading);
slm::SceneStats scene(const LatitudeReading& reading);

// What the graph is drawn from -- LatitudeReadout (Latitude.swift:335-385).
// `fractions` is the frame after `placement` (placed_histogram): what the
// render does with the committed curve, which is what macOS's "placed
// histogram" shows.
struct LatitudeReadout {
    std::vector<double> centres, fractions;
    double binWidth = 0;
    double shadowEv = 0, highlightEv = 0;
    double below = 0, within = 0, above = 0;
    // Lightness change per stop of the film + paper chain over its peak, at
    // the midpoint of each ramp step: the separation band's opacity.
    std::vector<std::pair<double, double>> separation;
    // Where separation is at least half its peak -- "full separation".
    std::optional<std::pair<double, double>> core;
};
LatitudeReadout readout(const LatitudeReading& reading, const SceneLatitudeParams& placement);

// --- Scene Placement ----------------------------------------------------

enum class Side { highlight, shadow };
const char* sideName(Side side);

// The engine's Fit for these pull-backs on this reading, `base` carrying the
// committed norm, roll-off and lift bound. The resolved curve to commit is
// committedCurve(): active only when a side is on, as spk_scene_latitude's
// params_delta says (engine.cpp, "scene_latitude_active = any").
slm::Fit fit(const LatitudeReading& reading, double highlight, double shadow, const SceneLatitudeParams& base);
SceneLatitudeParams committedCurve(const slm::Fit& fit);

// The pull-backs the Fit accepts on one side with the other held
// (PlacementWindow, Latitude.swift:135-214): least..most, or none. Zero --
// the side off -- is always accepted and is not part of it. Found by asking
// the Fit, as macOS does: walk up from the minimum to the first accepted
// value, then bisect each edge to the sliders' hundredth.
struct PlacementWindow {
    static constexpr const char* noWindowCode = "no_window";
    static constexpr double grain = 0.01;
    bool hasSpan = false;
    double least = 0, most = 0;
    slm::FitIssue below;                  // why a value under the span is refused
    std::optional<slm::FitIssue> above;   // and one over it
    // Where a slider's value lands: itself inside, the nearer edge outside,
    // 0 when there is no window -- with the reason it moved.
    std::pair<double, std::optional<slm::FitIssue>> landing(double asked) const;
};
// The track is macOS's 0..8 stops (Session.placementRange, Latitude.swift:403).
constexpr double placementLow = 0.0, placementHigh = 8.0;
PlacementWindow placementWindow(const LatitudeReading& reading, Side side, double other,
                                const SceneLatitudeParams& base);
// One refusal in the interface's words, for the row it is about -- macOS's
// English (Latitude.swift message(for:side:), :80-122); nullopt for a refusal
// about the other side. `minimum` is that side's minimum pull-back.
std::optional<std::string> refusalMessage(const slm::FitIssue& refusal, Side side, double minimum);

// --- Tone Mask ------------------------------------------------------------

// The mask's change in paper exposure, stops, at a blurred base `base` stops
// from the negative's mid-grey (ToneMaskCurve.delta, ToneMask.swift:34-45,
// itself a transcription of contrast_mask.cpp room_for / delta_at): an amount
// of N stops moves a base 4 stops past the core by exactly N.
double toneMaskDelta(double base, double highlights, double shadows, double core);

// --- the QML views ---------------------------------------------------------

QVariantMap latitudeVariant(const LatitudeReadout& readout);
QVariantMap issueVariant(const slm::FitIssue& issue);
QVariantMap windowVariant(const PlacementWindow& window);
// macOS's summary line (LatitudeSection.swift summary, :112-119), English:
// "4.31 stops held · −2.52 – +1.79 · full separation −1.80 – +1.10".
QString latitudeSummary(const LatitudeReadout& readout);

}  // namespace spk::desktop::predev
