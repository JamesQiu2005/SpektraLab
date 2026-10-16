#pragma once
// The Camera section's white-balance rules, as macOS states them, without a
// controller, a decode or an engine (macOS keeps them testable the same way,
// in WhiteBalanceBoxes, Model/Sidecar.swift:45-105): the two As Shot boxes,
// the sliders and the presets (Session.swift:2776-2814). And the eyedropper's
// one piece of geometry: from a point on the canvas to the photograph.
//
// The values are spk::desktop::WhiteBalance, the three settings rows
// (desktop/raw_white_balance.hpp); the decode applies them.
#include "FrameOutput.hpp"
#include "desktop/raw_white_balance.hpp"
#include <QPointF>
#include <QSize>
#include <optional>
#include <string>

namespace spk::desktop::predev {

// The camera's own pair, as the decode reports it (as_shot_white_balance);
// nullopt until a decode has landed, or for a camera LibRaw has no matrix for.
struct AsShot {
    double temperature = 0, tint = 0;
};

// What the two "As Shot" boxes read: a box is ticked when the decode uses the
// camera's value for that axis -- As Shot, or Custom pinned exactly to the
// camera's value, which is the same picture. With no camera pair both read
// unticked (and the boxes are disabled).
struct Boxes {
    bool temperature = false, tint = false;
};
Boxes boxes(const WhiteBalance& value, const std::optional<AsShot>& camera);

// Each edit returns the white balance to store; the arguments are not
// changed. macOS's numbers under As Shot *are* the camera's (filled in after
// the decode, Sidecar.swift:23-24); here they may be stale, so each edit
// first makes them the camera's, clamped to the rows' ranges -- leaving As
// Shot by one axis keeps the other where the picture had it.
//
// A box ticked pins its axis to the camera's value; both ticked is As Shot;
// unticked is Custom where it was (WhiteBalanceBoxes.applying). nullopt
// leaves a box alone. Without a camera pair nothing changes.
WhiteBalance applyingBoxes(const WhiteBalance& value, std::optional<bool> temperature, std::optional<bool> tint,
                           const std::optional<AsShot>& camera);
// A slider: Custom at the value (Session.setTemperature / setTint).
WhiteBalance withTemperature(const WhiteBalance& value, double kelvin, const std::optional<AsShot>& camera);
WhiteBalance withTint(const WhiteBalance& value, double tint, const std::optional<AsShot>& camera);
// A preset (Session.setWhiteBalance): its Kelvin at tint 0; As Shot the
// camera's pair when there is one. nullopt for an id that is no preset.
std::optional<WhiteBalance> withPreset(const WhiteBalance& value, const std::string& id,
                                       const std::optional<AsShot>& camera);

// The eyedropper's point. QML hands a point normalised to the picture it
// shows -- after crop, straighten, quarter turns and flips (FrameOutput's
// applyGeometry order) -- and the RAW is sampled in the photograph's own
// frame: this inverts that geometry, pixel edges as cropPixels rounds them
// and straightening's own centre and zoom. The result is normalised to the
// full frame, top-left origin; nullopt for a point outside [0, 1] or an
// invalid geometry.
std::optional<QPointF> sourcePoint(QSize fullSize, const output::Geometry& geometry, QPointF shown);

}  // namespace spk::desktop::predev
