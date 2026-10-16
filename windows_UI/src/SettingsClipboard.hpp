#pragma once

#include "desktop/preview_host.hpp"
#include <QSet>
#include <QString>
#include <QStringList>
#include <optional>
#include <string_view>
#include <vector>

// The settings clipboard (SettingsClipboard.swift, RFC-027): Capture One's
// adjustments clipboard with the macOS app's seven groups, on the Windows
// settings table.
//
// The groups are ticked at copy time: a clip is the source photograph's
// settings plus the groups it was taken with, and a paste writes exactly
// those. A paste writes settings, not solved numbers (the user's decision,
// 2026-09-28): the target meters its own exposure, keeps its own camera white
// balance under As Shot and fits its own Scene Placement -- the source's fitted
// curve is never pasted (SettingsClipboard.swift:7-12).
//
// `applied` is pure, settings in and settings out, so the whole meaning of a
// paste is testable without a window, an engine or a file; the controller
// decides only how the result reaches a photograph.
namespace spk::desktop::clipboard {

enum class Group { filmAndPaper, exposure, whiteBalance, filmEffects, printEffects, scenePlacement, masks };

struct GroupInfo {
    Group group;
    const char* id;          // the section's key, the L10n suffix and the stored name
    std::vector<const char*> keys;   // the settings rows the group owns
};
// In the section's order (ClipboardGroup.allCases).
const std::vector<GroupInfo>& groups();
const GroupInfo& info(Group group);
std::optional<Group> groupNamed(const QString& id);
QString name(Group group);
QSet<Group> allGroups();
// The boxes the section shows (ClipboardGroup.offered). macOS hides 遮罩
// while both the masks and the Tone Mask are withdrawn there; this build
// shows the Tone Mask section (qml/right/ToneMaskSection.qml), so a box for
// it is a box for settings the user can see and change, and it is offered.
std::vector<Group> offered();

// Rows and photograph state no group owns, and why (ClipboardGroup.notCopied):
// a key, or a prefix ending in '_' or '*'.
struct NotCopied { const char* key; const char* reason; };
const std::vector<NotCopied>& notCopied();
// Every settings row has exactly one owner or a notCopied reason; this names
// it -- a group's id, "notCopied", or "" for a row nobody has decided about
// (spk_qt_library goes red for that, as SettingsClipboardTests does).
QString ownerOf(std::string_view key);

struct Clip {
    QSet<Group> groups;
    RenderSettings settings;   // the source photograph's settings when copied
    QString sourceName;        // the section's "what is held" line
    // `target` with this clip's groups written into it, and nothing else
    // (SettingsClip.applied, SettingsClipboard.swift:122-191).
    RenderSettings applied(const RenderSettings& target) const;
};

}  // namespace spk::desktop::clipboard
