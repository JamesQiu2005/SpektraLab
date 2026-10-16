#include "SettingsClipboard.hpp"

#include <algorithm>
#include <string>

namespace spk::desktop::clipboard {
namespace {
double number(const RenderSettings& s, const char* key) { return std::get<double>(s.get(key)); }
void copy(RenderSettings& to, const RenderSettings& from, const char* key) { to.set(key, from.get(key)); }
void reset(RenderSettings& s, const char* key) { s.set(key, find_setting(key)->initial); }
bool matches(std::string_view key, std::string_view pattern) {
    if (!pattern.empty() && (pattern.back() == '_' || pattern.back() == '*'))
        return key.starts_with(pattern.substr(0, pattern.back() == '*' ? pattern.size() - 1 : pattern.size()));
    return key == pattern;
}
}  // namespace

const std::vector<GroupInfo>& groups() {
    // ClipboardGroup.paths (SettingsClipboard.swift:39-64), by this build's
    // rows. Where a macOS field has no row here (digitalIntermediate and
    // extendedDynamicRange; filmFrame, filmSide and sideLengthMM, which only
    // derive film_format_mm; the placement's percentiles), there is nothing
    // to carry.
    static const std::vector<GroupInfo> table{
        {Group::filmAndPaper, "filmAndPaper", {"film_stock", "print_stock", "scan_film"}},
        // The enlarger's brightness is the print's exposure (user, 2026-09-28).
        {Group::exposure, "exposure",
         {"auto_exposure", "auto_exposure_method", "exposure_compensation_ev", "print_exposure"}},
        // The enlarger's filters: in the darkroom, colour is the filter pack;
        // the scale is the unit those two are counted in (API-SPEC §14).
        {Group::whiteBalance, "whiteBalance",
         {"white_balance", "white_balance_temperature", "white_balance_tint", "y_filter_shift", "m_filter_shift",
          "filter_shift_scale"}},
        // The film format sets the physical scale of grain and halation.
        {Group::filmEffects, "filmEffects",
         {"film_format_mm", "grain_active", "grain_amount", "grain_sublayers_active", "halation_active",
          "halation_amount", "antihalation_removed", "halation_scatter_amount", "halation_boost_ev",
          "dir_couplers_active", "dir_couplers_amount", "glare_active", "glare_amount"}},
        // Pre-flash is gated by the Print Effects switch already.
        {Group::printEffects, "printEffects", {"print_effects", "preflash_exposure"}},
        {Group::scenePlacement, "scenePlacement",
         {"scene_latitude_active", "scene_latitude_norm", "scene_latitude_highlight_knee",
          "scene_latitude_highlight_room", "scene_latitude_shadow_knee", "scene_latitude_shadow_room",
          "scene_latitude_rolloff", "scene_latitude_max_lift", "scene_latitude_highlight_pull_back",
          "scene_latitude_shadow_pull_back", "scene_latitude_needs_fit"}},
        {Group::masks, "masks",
         {"contrast_mask_active", "contrast_mask_highlights", "contrast_mask_shadows", "contrast_mask_core",
          "contrast_mask_scale", "contrast_mask_scheme"}},
    };
    return table;
}

const GroupInfo& info(Group group) {
    for (const auto& g : groups())
        if (g.group == group) return g;
    return groups().front();
}

std::optional<Group> groupNamed(const QString& id) {
    for (const auto& g : groups())
        if (id == QLatin1String(g.id)) return g.group;
    return std::nullopt;
}

QString name(Group group) { return QLatin1String(info(group).id); }

QSet<Group> allGroups() {
    QSet<Group> out;
    for (const auto& g : groups()) out.insert(g.group);
    return out;
}

std::vector<Group> offered() {
    std::vector<Group> out;
    for (const auto& g : groups()) out.push_back(g.group);
    return out;
}

const std::vector<NotCopied>& notCopied() {
    // ClipboardGroup.notCopied (SettingsClipboard.swift:67-87), by this build's
    // rows and the photograph's own state beside them.
    static const std::vector<NotCopied> table{
        // Undecided on macOS (answer sheet F10): whether Film Edge and Date
        // Back become a group. Until then neither is copied, and the seeds and
        // the resolved text would be the source photograph's anyway.
        {"overscan_*", "Film Edge: not copied until a group is decided (F10)"},
        {"film_edge_seeded", "Film Edge: whether this photograph has its own seeds"},
        {"date_imprint_*", "Date Back: not copied until a group is decided (F10)"},
        {"date_back_*", "Date Back: not copied until a group is decided (F10)"},        // Not settings rows: the photograph's own state in its record.
        {"geometry", "crop and framing belong to the photograph (PRD §7)"},
        {"heldGeometry", "the photograph's own crop, kept while Film Edge frames it"},
        {"postDev", "the Post-Dev grade, outside the 2026-09-23 positioning"},
        {"decodeMode", "the file's decode (macOS: decoder, the file format)"},
        {"pair", "a half-frame pair's piece and its frames' own state"},
    };
    return table;
}

QString ownerOf(std::string_view key) {
    QString owner;
    int owners = 0;
    for (const auto& g : groups())
        for (const char* k : g.keys)
            if (key == k) { owner = QLatin1String(g.id); ++owners; }
    for (const auto& n : notCopied())
        if (matches(key, n.key)) { owner = QStringLiteral("notCopied"); ++owners; }
    return owners == 1 ? owner : QString();
}

RenderSettings Clip::applied(const RenderSettings& target) const {
    RenderSettings out = target;
    const RenderSettings& s = settings;
    const auto take = [&](Group group) {
        for (const char* key : info(group).keys) copy(out, s, key);
    };
    if (groups.contains(Group::filmAndPaper)) take(Group::filmAndPaper);
    if (groups.contains(Group::exposure)) take(Group::exposure);
    if (groups.contains(Group::whiteBalance)) {
        copy(out, s, "white_balance");
        // As Shot is the *target's* camera: its numbers are its own, and the
        // source's Kelvin must not come with the word (:145-150).
        if (std::get<std::string>(s.get("white_balance")) != "as_shot") {
            copy(out, s, "white_balance_temperature");
            copy(out, s, "white_balance_tint");
        }
        for (const char* key : {"y_filter_shift", "m_filter_shift", "filter_shift_scale"}) copy(out, s, key);
    }
    if (groups.contains(Group::filmEffects)) take(Group::filmEffects);
    if (groups.contains(Group::printEffects)) take(Group::printEffects);
    if (groups.contains(Group::scenePlacement)) {
        // The intent and the Fit's inputs; the curve stays the identity until
        // the target's own Fit lands (:171-185, resolvePendingPlacement).
        for (const char* key : {"scene_latitude_norm", "scene_latitude_rolloff", "scene_latitude_max_lift",
                                "scene_latitude_highlight_pull_back", "scene_latitude_shadow_pull_back"})
            copy(out, s, key);
        for (const char* key : {"scene_latitude_active", "scene_latitude_highlight_knee", "scene_latitude_highlight_room",
                                "scene_latitude_shadow_knee", "scene_latitude_shadow_room"})
            reset(out, key);
        out.set("scene_latitude_needs_fit", number(out, "scene_latitude_highlight_pull_back") > 0 ||
                                                number(out, "scene_latitude_shadow_pull_back") > 0);
    }
    if (groups.contains(Group::masks)) take(Group::masks);
    return out;
}

}  // namespace spk::desktop::clipboard
