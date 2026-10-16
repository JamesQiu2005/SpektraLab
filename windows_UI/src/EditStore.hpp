#pragma once

#include "FrameOutput.hpp"
#include <QHash>
#include <QString>
#include <QStringList>
#include <QUrl>
#include <optional>

// Per-photo edits belong to the application's own directory, never beside a
// RAW. The directory is mandatory so test callers cannot reach the real store.
//
// Document version 2 ("SpektraLab.Windows.Editor"):
//   { "format", "version": 2, "source": {path, size, mtimeMs, sampleSha256},
//     "state": { "settings": { <wire name>: value, ... },
//                "decodeMode": "compatible16" | "headroom",
//                "geometry": { "crop": {x, y, width, height}, "quarterTurns",
//                              "flipHorizontal", "flipVertical", "straightenDegrees" },
//                "heldGeometry": null | { as "geometry" } } }   (optional)
// Settings are keyed by the desktop settings table (preview_host.hpp) and
// validated against its type, range and choices. Version 1's thirteen keys
// are required; a row added since is optional and, when absent, takes the
// value the record was rendered with (the row's `absent`). A key this build
// does not know -- in the document, state, settings or geometry -- is a
// newer build's field: it is ignored and kept as it was by the next save.
// Source and crop stay exact. Version 1 records still load (their
// film_exposure_ev is the wire's exposure_compensation_ev) and are rewritten
// as version 2 by the first save; any later version is preserved, never read.
namespace spk::desktop::editing {

struct State {
    RenderSettings settings;
    DecodeMode mode = DecodeMode::compatible16;
    output::Geometry geometry;
    // The user's own crop while a film edge holds `geometry` at its gate's
    // shape, given back when the film edge is switched off (macOS
    // Sidecar.heldCrop, Session+FilmEdge.swift:396-417). Saved as the
    // optional "state.heldGeometry", null when there is none.
    std::optional<output::Geometry> heldGeometry;
    bool operator==(const State&) const = default;
};

struct LoadResult {
    std::optional<State> state;
    QString warning;
    // A record exists but cannot safely be replaced (or its source cannot be
    // checked). The editor can still work in memory and should show a warning.
    bool blocked = false;
    // The document version that was read (0: no record, or it was refused).
    int version = 0;
    // Fields of a newer build this one ignores, as dotted paths
    // ("state.settings.<key>"). The next save keeps them unchanged.
    QStringList preserved;
};

class Store final {
public:
    explicit Store(QString directory);
    LoadResult load(const QUrl& source, const Catalog& catalog) const;
    // Atomic replacement after validating the existing record and source.
    // Throws std::runtime_error; a rejected save leaves old edits untouched.
    void save(const QUrl& source, const State& state) const;
    QString filePath(const QUrl& source) const;

private:
    struct Observation {
        QByteArray source, record;
        QString warning;
        std::optional<Catalog> catalog;
    };
    QString directory_;
    // All calls belong to the controller thread. Remember what it loaded so
    // a changed source or another app instance cannot silently lose edits.
    mutable QHash<QString, Observation> observations_;
};

} // namespace spk::desktop::editing
