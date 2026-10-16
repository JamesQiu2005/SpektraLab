import QtQuick

// Scene Placement (ParameterSections.swift, RFC-023): how many stops the
// scene's top and bottom are drawn in toward the medium before the film sees
// them, through the latitude fit the graph above shows.
//
// The Windows engine boundary does not carry the pull-backs yet, so the rows
// keep their place greyed with the reason; a later lane wires them (and the
// Mac's usable band on each track) through the settings table.
MacSection {
    sectionId: "scenePlacement"
    title: L10n.tr("placement.title")
    resetVisible: true
    resetAvailable: false
    resetToolTip: L10n.tr("placement.reset")
    resetReason: L10n.tr("placeholder.scenePlacement")

    ScrubSlider {
        label: L10n.tr("placement.highlight")
        from: 0; to: 4; defaultValue: 0; step: 0.05
        value: 0
        available: false
        reason: L10n.tr("placeholder.scenePlacement")
    }
    ScrubSlider {
        label: L10n.tr("placement.shadow")
        from: 0; to: 4; defaultValue: 0; step: 0.05
        value: 0
        available: false
        reason: L10n.tr("placeholder.scenePlacement")
    }
}
