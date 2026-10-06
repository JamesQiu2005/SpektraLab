#pragma once

#include "FrameOutput.hpp"
#include <QHash>
#include <QString>
#include <QUrl>
#include <optional>

// Per-photo edits belong to the application's own directory, never beside a
// RAW. The directory is mandatory so test callers cannot reach the real store.
namespace spk::desktop::editing {

struct State {
    RenderSettings settings;
    DecodeMode mode = DecodeMode::compatible16;
    output::Geometry geometry;
    bool operator==(const State&) const = default;
};

struct LoadResult {
    std::optional<State> state;
    QString warning;
    // A record exists but cannot safely be replaced (or its source cannot be
    // checked). The editor can still work in memory and should show a warning.
    bool blocked = false;
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
