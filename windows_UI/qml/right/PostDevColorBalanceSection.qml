import QtQuick
import QtQuick.Controls

// Post-Dev Color Balance (RightSections.swift ColorBalanceSection): the four
// zones' wheels with their saturation and luminance arcs, folded by default.
MacSection {
    sectionId: "postDev.colorBalance"
    title: L10n.tr("postDev.colorBalance")
    defaultExpanded: false
    resetVisible: true
    resetAvailable: preview.settingsEditable && preview.hasFrame
    resetToolTip: L10n.tr("postDev.resetColorBalance")
    onResetRequested: preview.resetPostDev("colorBalance")
    menuItems: [
        RailMenuItem { text: L10n.tr("postDev.reset"); enabled: preview.settingsEditable && preview.hasFrame; onTriggered: preview.resetPostDev("colorBalance") }
    ]

    ColorBalanceEditor { objectName: "colorBalanceEditor" }
}
