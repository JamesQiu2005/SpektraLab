#pragma once
// A half-frame pair as the Windows editor keeps it: macOS Model/HalfFramePair
// .swift's piece (which frame is in which hole, where each picture sits under
// its hole, how far apart the holes are, which way the camera was held) and
// each frame's own state, persisted in the edit store's directory under the
// pair's own record (<edits>/Pairs/<name>.spkpair). The record is the pair's
// identity in the filmstrip, as the .spektrapair file is on the Mac. The
// photographs' own records are only ever read.
//
// What a frame of a pair has for itself (Session+... focusSide, pickedHole,
// Session.swift:4956-5108):
//   camera   its white balance (the decode), its meter and Film Exposure, its
//            Scene Placement -- cameraKeys(); the rows the Input / Camera and
//            Scene Placement sections show while it is picked;
//   print    its own enlarger (brightness, both filters, pre-flash) once it is
//            given one -- printKeys(); nil prints as the film does;
//   scopes   Frame or + Film: whether an edit of the frame also moves the film
//            around it by the same amount (answers B1-B3);
//   postDev  its own Post-Dev grade, kept opaque for the Post-Dev lane.
// Everything else -- stocks, effects, Film Edge, Date Back -- is the pair's
// own settings (the film), stored in the record's "state" exactly as a
// photograph's edit (EditStore.hpp, version 2).
//
// The rails show one settings object (PreviewController::settings()); shown()
// builds it from the film and the picked frame, and takeEdit() puts an edit of
// it back where it belongs, so every existing control works on a pair
// unchanged.
#include "FrameOutput.hpp"
#include "desktop/preview_host.hpp"
#include <QJsonObject>
#include <QString>
#include <QStringList>
#include <array>
#include <optional>
#include <string_view>
#include <vector>

namespace spk::desktop::editing { struct State; }

namespace spk::desktop::pairs {

enum class Scope { frame, film };
// The layer the Half-Frame Pair section and the canvas have picked: the film
// (the gap, the rebate) or one hole (PairLayer).
enum class Layer { film = 0, first = 1, second = 2 };

const std::vector<std::string>& cameraKeys();
const std::vector<std::string>& printKeys();
bool cameraKey(std::string_view key);
bool printKey(std::string_view key);

struct Hole {
    QString path;                        // the photograph, absolute
    PairPlacement placement;
    output::Geometry geometry;           // the frame's own crop/turn/flips, read from its record
    RenderSettings frame;                // its camera rows (cameraKeys)
    std::optional<RenderSettings> print; // its own print (printKeys), or the film's
    Scope printScope = Scope::film;      // the enlarger starts on the film as well
    Scope exposureScope = Scope::frame;  // exposure on the frame (answers B1-B3)
    QJsonObject postDev;                 // its own Post-Dev grade, opaque here
    bool operator==(const Hole&) const = default;
};

struct Pair {
    QString folder;                      // the folder whose filmstrip it belongs to
    std::array<std::optional<Hole>, 2> holes;
    double spacingMM = 1.0;              // the user's gap without a strip
    bool turned = false;                 // the camera turned: holes stacked
    bool operator==(const Pair&) const = default;

    // The gap the layout uses: the camera's 1 mm on a strip (Film Edge on).
    double effectiveSpacing(bool onStrip) const;
    int filled() const;
    // Both holes hold a frame still on disk (answer B9: an empty hole is not exported).
    bool complete() const;
};

// --- files -------------------------------------------------------------------

inline constexpr const char* kExtension = "spkpair";
bool isPairFile(const QString& path);
QString storeDirectory(const QString& editDirectory);
// "Half-Frame Pair 3 <tag>.spkpair": the first number no pair file has.
QString newPairPath(const QString& editDirectory, const QString& folder);
// "Half-Frame Pair 3".
QString title(const QString& path);
// The pairs in the store that belong to `folder` (case-insensitive), in name order.
QStringList pairsIn(const QString& editDirectory, const QString& folder);

// Document "SpektraLab.Windows.HalfFramePair", version 1:
//   { "format", "version": 1,
//     "pair": { "folder", "turned", "spacingMM",
//               "holes": [ null | { "path", "placement": {scale, x, y, quarterTurns},
//                                   "geometry": <EditStore geometry>,
//                                   "frame": { <camera row>: value, ... },
//                                   "print": null | { <print row>: value, ... },
//                                   "printScope": "film"|"frame", "exposureScope": "frame"|"film",
//                                   "postDev": {...} }, x2 ] },
//     "state": <EditStore state: the film's settings, decodeMode, geometry, heldGeometry> }
// Rows are checked against the settings table as the edit store checks them;
// a key this build does not know is kept by the next save.
struct Loaded {
    std::optional<Pair> pair;
    QString warning;
    QStringList preserved;
};
Loaded load(const QString& path, const Catalog* catalog, editing::State& state);
// Atomic; keeps fields a newer build wrote. Throws std::runtime_error.
void save(const QString& path, const Pair& pair, const editing::State& state);

// --- the rails ---------------------------------------------------------------

// The frame the camera rows are about: the picked hole, else the one picked
// last (`cameraSide`), else the first filled one; -1 for an empty pair.
int cameraSide(const Pair& pair, Layer layer, int lastCameraSide);
// The settings the rails show with `layer` picked.
RenderSettings shown(const RenderSettings& film, const Pair& pair, Layer layer, int lastCameraSide);
// An edit of the shown settings, put back where it belongs (Session.setEnlarger,
// setHoleExposure, layerAdjustments): camera rows to the camera frame (its
// exposure moving the film's print by the same stops on + Film); print rows to
// the picked frame's own print, both frames given one first, the film moving
// with it on + Film -- or, with the film picked, to the film, frames with a
// print of their own moving by the same amount; every other row to the film.
void takeEdit(const RenderSettings& shownNow, RenderSettings& film, Pair& pair, Layer layer, int lastCameraSide);

// --- the engine --------------------------------------------------------------

// The settings the piece is developed with: the film's, the meter off and no
// Film Exposure (each hole is exposed on its own, PairComposer.exposed), the
// first frame's Scene Placement, film_format_mm the piece.
RenderSettings engineSettings(const RenderSettings& film, const Pair& pair);
// What the host composes: each hole's photograph, decode, geometry, placement,
// exposure, meter and own print; the second frame's curve.
PairInput engineInput(const RenderSettings& film, const Pair& pair);
// A new hole for a photograph: its own decode, geometry, meter and placement
// read from its record's settings (`own`, or the defaults).
Hole holeFor(const QString& path, const RenderSettings* own, const output::Geometry& geometry);

}  // namespace spk::desktop::pairs
