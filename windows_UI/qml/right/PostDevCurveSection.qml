import QtQuick
import QtQuick.Controls

// Post-Dev Curve (RightSections.swift CurveSection): the curve tool, open by
// default; the section's menu resets every channel ("Reset channels").
MacSection {
    sectionId: "postDev.curve"
    title: L10n.tr("postDev.curve")
    resetVisible: true
    resetAvailable: preview.settingsEditable && preview.hasFrame
    resetToolTip: L10n.tr("postDev.resetChannels")
    onResetRequested: preview.resetPostDev("curves")
    menuItems: [
        RailMenuItem { text: L10n.tr("postDev.resetChannels"); enabled: preview.settingsEditable && preview.hasFrame; onTriggered: preview.resetPostDev("curves") }
    ]

    CurveEditor { objectName: "curveEditor" }
}
