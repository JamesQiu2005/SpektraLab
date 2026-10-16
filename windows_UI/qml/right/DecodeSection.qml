import QtQuick

// RAW Decode (Windows only): the validated compatible decode, or the
// experimental one that keeps highlight headroom. A change re-opens the
// photo. The Mac decodes through Core Image and has no such choice; here it
// is a section like any other, after the Mac's.
MacSection {
    sectionId: "decode"
    title: L10n.tr("decode.title")

    ParamRow {
        label: L10n.tr("decode.mode")
        available: preview.settingsEditable
        PillDropdown {
            model: [L10n.tr("decode.compatible"), L10n.tr("decode.headroom")]
            // Reads `model` so a language switch re-runs the binding.
            currentIndex: { model; return preview.decodeMode }
            onActivated: function(index) { preview.decodeMode = index }
        }
    }
    Note { text: preview.decodeMode ? L10n.tr("decode.headroomNote") : L10n.tr("decode.compatibleNote") }
}
