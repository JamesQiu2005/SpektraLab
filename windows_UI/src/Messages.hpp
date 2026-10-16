#pragma once
// Every user-visible string the Qt app's C++ produces (status lines, saved-edit
// notes), under a stable namespaced key, in English (en-US). Placeholders are
// {0}, {1}, ... in argument order. Keeping them in one table is what lets a
// localiser replace uiText() with its own tr(key, args) later without touching
// a call site; nothing here chooses a language. Errors raised by the engine,
// the host and the edit store are English diagnostics and pass through as-is.
#include <QString>
#include <QStringList>
#include <string_view>

namespace spk::desktop::messages {

struct Message { const char* key; const char* english; };

inline constexpr Message kMessages[] = {
    {"status.startingEngine", "Starting the render engine…"},
    {"status.ready", "Ready · open a RAW file to begin"},
    {"status.opening", "Decoding and rendering the RAW file…"},
    {"status.rendering", "Updating the film look…"},
    {"status.updatingPreview", "Updating preview…"},
    {"status.previewCurrent", "Preview already shows the current settings"},
    {"status.rendered", "Rendered in {0} s"},
    {"status.renderedReusedNegative", "Rendered in {0} s · negative reused"},
    {"status.exporting", "Exporting the current frame…"},
    {"status.exported", "Exported the current frame"},
    {"status.batchExporting", "Exporting the batch…"},
    {"status.batchFinished", "Batch export finished: {0} exported, {1} skipped (file exists), {2} failed"},
    {"status.batchCancelled", "Batch export cancelled: {0} exported, {1} skipped (file exists), {2} failed"},
    // macOS: "Photos synced: %d." (Strings.swift clipSyncDone).
    {"status.syncedWithCrop", "Photos synced: {0} (crops included)."},
    {"status.syncedKeepingCrops", "Photos synced: {0} (each keeps its own crop)."},
    {"status.undone", "Undid the last adjustment to this photo"},
    {"status.redone", "Redid the adjustment to this photo"},
    {"saved.unsaved", "Some settings are not saved; see the warning below"},
    {"saved.saving", "Saving settings…"},
    {"saved.saved", "This photo's settings are saved"},
    {"saved.automatic", "Adjustments save automatically and return when the photo is reopened"},
    {"saved.newerFields", " · {0} settings from a newer version are not used here and are kept as they are"},
};

inline QString format(std::string_view key, const QStringList& args = {}) {
    for (const auto& message : kMessages) {
        if (key != message.key) continue;
        QString text = QString::fromUtf8(message.english);
        for (qsizetype i = 0; i < args.size(); ++i)
            text.replace(QStringLiteral("{%1}").arg(i), args[i]);
        return text;
    }
    // A missing key shows itself rather than an empty status line.
    return QString::fromUtf8(key.data(), qsizetype(key.size()));
}

} // namespace spk::desktop::messages

// The call-site spelling: uiText("status.rendered", {seconds}).
inline QString uiText(std::string_view key, const QStringList& args = {}) {
    return spk::desktop::messages::format(key, args);
}
