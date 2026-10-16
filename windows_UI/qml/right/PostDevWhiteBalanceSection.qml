import QtQuick
import QtQuick.Controls

// Post-Dev White Balance (RightSections.swift WhiteBalanceSection): an offset
// on the finished print, Temp. and Tint, -100..100 with the Mac's gradient
// tracks, folded by default. Not the decode pair in Pre-Dev's Camera section,
// which sets the RAW's white balance; the caption says which this is.
MacSection {
    sectionId: "postDev.whiteBalance"
    title: L10n.tr("postDev.whiteBalance")
    defaultExpanded: false
    resetVisible: true
    resetAvailable: preview.settingsEditable && preview.hasFrame
    resetToolTip: L10n.tr("postDev.resetWhiteBalance")
    onResetRequested: preview.resetPostDev("whiteBalance")
    menuItems: [
        RailMenuItem { text: L10n.tr("postDev.reset"); enabled: preview.settingsEditable && preview.hasFrame; onTriggered: preview.resetPostDev("whiteBalance") }
    ]

    PostDevSlider {
        objectName: "postDevTemperature"
        path: "temperature"
        label: L10n.tr("postDev.temperature")
        gradient: ["#005982", "#8fa83c", "#fff100"]
    }
    PostDevSlider {
        path: "tint"
        label: L10n.tr("postDev.tint")
        gradient: ["#00a93a", "#8aa45e", "#e4007f"]
    }
    Note { text: L10n.tr("postDev.whiteBalanceScope") }
}
