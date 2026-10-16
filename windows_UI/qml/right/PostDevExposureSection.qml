import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Post-Dev Exposure (RightSections.swift ExposureSection): the four global
// controls, a hairline, then the four that reach into a tonal range -- the
// Mac's ranges, snaps and formats ("%+.2f" exposure, "%.0f" for the two
// points). Folded by default, like the Mac's.
MacSection {
    sectionId: "postDev.exposure"
    title: L10n.tr("postDev.exposure")
    defaultExpanded: false
    resetVisible: true
    resetAvailable: preview.settingsEditable && preview.hasFrame
    resetToolTip: L10n.tr("postDev.resetExposure")
    onResetRequested: preview.resetPostDev("exposure")
    menuItems: [
        RailMenuItem { text: L10n.tr("postDev.reset"); enabled: preview.settingsEditable && preview.hasFrame; onTriggered: preview.resetPostDev("exposure") }
    ]

    PostDevSlider { objectName: "postDevExposure"; path: "exposure"; label: L10n.tr("postDev.exposureSlider"); decimals: 2 }
    PostDevSlider { path: "contrast"; label: L10n.tr("postDev.contrast") }
    PostDevSlider { path: "brightness"; label: L10n.tr("postDev.brightness") }
    PostDevSlider { path: "saturation"; label: L10n.tr("postDev.saturation") }
    // The same wall as between sections, one storey down.
    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; Layout.topMargin: 2; Layout.bottomMargin: 2; color: Theme.rule }
    PostDevSlider { path: "highlights"; label: L10n.tr("postDev.highlights") }
    PostDevSlider { path: "shadows"; label: L10n.tr("postDev.shadows") }
    PostDevSlider { path: "blackPoint"; label: L10n.tr("postDev.blackPoint"); signed: false }
    PostDevSlider { path: "whitePoint"; label: L10n.tr("postDev.whitePoint"); signed: false }
}
