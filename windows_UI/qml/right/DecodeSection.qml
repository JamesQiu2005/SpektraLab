import QtQuick

// RAW Decode (Windows only): how the photograph is turned into the scene the
// film is exposed to. The Mac decodes through Core Image and has no such
// section; here it sits before Scene Placement, in the pipeline's order.
//
// Decode: the validated compatible decode, or the experimental one that keeps
// highlight headroom. A change re-opens the photo.
//
// Highlights and Shadows (scene_tone_*, API-SPEC §16): a local move on the
// scene after the meter and before Scene Placement -- judged against an
// edge-aware base of the frame's brightness, so a bright or dark region moves
// as a whole and the detail inside it is kept. -100..100, up to 2 stops at the
// far end of each side; a shoot edit, so it re-develops. Unlike Decode it
// works on a TIFF, JPEG or PNG too: it acts on the scene, not on the RAW.
// Each drag is one undo step; the header's reset puts both back to 0.
MacSection {
    id: decode
    sectionId: "decode"
    title: L10n.tr("decode.title")
    // A TIFF, JPEG or PNG is decoded from its own encoding, with no RAW
    // decode to choose.
    readonly property bool raw: !preview.hasFrame || preview.metadata.raw !== false
    readonly property real highlights: Number(preview.parameters.scene_tone_highlights || 0)
    readonly property real shadows: Number(preview.parameters.scene_tone_shadows || 0)
    resetVisible: true
    resetAvailable: preview.settingsEditable && (highlights !== 0 || shadows !== 0)
    resetToolTip: L10n.tr("decode.toneReset")
    onResetRequested: preview.setParameters({ scene_tone_highlights: 0, scene_tone_shadows: 0 })

    ParamRow {
        label: L10n.tr("decode.mode")
        available: preview.settingsEditable && decode.raw
        reason: decode.raw ? "" : L10n.tr("decode.flatReason")
        PillDropdown {
            model: [L10n.tr("decode.compatible"), L10n.tr("decode.headroom")]
            // Reads `model` so a language switch re-runs the binding.
            currentIndex: { model; return preview.decodeMode }
            onActivated: function(index) { preview.decodeMode = index }
        }
    }
    Note { text: preview.decodeMode ? L10n.tr("decode.headroomNote") : L10n.tr("decode.compatibleNote") }
    ScrubSlider {
        objectName: "sceneToneHighlightsSlider"
        label: L10n.tr("decode.highlights")
        from: -100; to: 100; defaultValue: 0
        step: 1; snap: 5; decimals: 0; signed: true
        value: decode.highlights
        gestureKey: "scene_tone_highlights"
        available: preview.settingsEditable
        toolTip: L10n.tr("decode.highlightsHelp")
        onMoved: function(v) { preview.setParameter("scene_tone_highlights", v) }
    }
    ScrubSlider {
        objectName: "sceneToneShadowsSlider"
        label: L10n.tr("decode.shadows")
        from: -100; to: 100; defaultValue: 0
        step: 1; snap: 5; decimals: 0; signed: true
        value: decode.shadows
        gestureKey: "scene_tone_shadows"
        available: preview.settingsEditable
        toolTip: L10n.tr("decode.shadowsHelp")
        onMoved: function(v) { preview.setParameter("scene_tone_shadows", v) }
    }
}
