import QtQuick

// Scene Placement (ParameterSections.swift:200-258, RFC-023): how many stops
// the scene's top and bottom are drawn in toward the medium before the film
// sees them. The Latitude graph above shows where they land.
//
// Every value goes through the Fit, and the Fit takes a window of pull-backs
// on each side rather than everything above zero. The window is drawn as a
// band around the track (ScrubSlider `usable`) and a slider cannot rest
// outside it: preview.placeScene brings a dragged or typed value onto the
// band's nearer edge, solves the curve on the last measurement and commits
// it, so the row shows what is committed and nothing else. A drag is one undo
// step (gesture key "scene_placement"). Each row says why it stopped, or why
// no pull-back works, on its second line (the controller's messages).
//
// The rows wait for a measurement of the current controls
// (scenePlacement.enabled): after a film, paper, enlarger or decode edit,
// until that render is measured. The knee / room rows behind the curve are
// the Fit's output, not controls, and nothing here binds them.
MacSection {
    id: section
    sectionId: "scenePlacement"
    title: L10n.tr("placement.title")
    readonly property var placement: preview.scenePlacement
    readonly property bool rowsAvailable: preview.settingsEditable && placement.enabled === true
    readonly property string reason: !preview.hasFrame || preview.latitude.available !== true
                                     ? L10n.tr("placement.reasonNotDeveloped") : L10n.tr("placement.reasonMeasuring")
    readonly property real highlight: Number(placement.highlight || 0)
    readonly property real shadow: Number(placement.shadow || 0)
    function band(window) {
        return window && window.hasSpan === true ? [[Number(window.from), Number(window.to)]] : []
    }
    resetVisible: true
    resetAvailable: preview.settingsEditable && placement.active === true
    resetToolTip: L10n.tr("placement.reset")
    onResetRequested: preview.resetScenePlacement()

    ScrubSlider {
        objectName: "placementHighlightSlider"
        label: L10n.tr("placement.highlight")
        sublabel: section.placement.highlightMessage || ""
        from: section.placement.from === undefined ? 0 : section.placement.from
        to: section.placement.to === undefined ? 8 : section.placement.to
        defaultValue: 0; step: 0.05; snap: 0.25; decimals: 2
        value: section.highlight
        usable: section.band(section.placement.highlightWindow)
        gestureKey: "scene_placement"
        available: section.rowsAvailable
        reason: section.reason
        toolTip: section.placement.highlightMessage ? section.placement.highlightMessage : L10n.tr("placement.highlightHelp")
        onMoved: function(v) { preview.placeScene(v, section.shadow, "highlight") }
    }
    ScrubSlider {
        objectName: "placementShadowSlider"
        label: L10n.tr("placement.shadow")
        sublabel: section.placement.shadowMessage || ""
        from: section.placement.from === undefined ? 0 : section.placement.from
        to: section.placement.to === undefined ? 8 : section.placement.to
        defaultValue: 0; step: 0.05; snap: 0.25; decimals: 2
        value: section.shadow
        usable: section.band(section.placement.shadowWindow)
        gestureKey: "scene_placement"
        available: section.rowsAvailable
        reason: section.reason
        toolTip: section.placement.shadowMessage ? section.placement.shadowMessage : L10n.tr("placement.shadowHelp")
        onMoved: function(v) { preview.placeScene(section.highlight, v, "shadow") }
    }
}
