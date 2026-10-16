import QtQuick
import QtQuick.Controls

// Vignetting: Layer 2's radial fall-off about the uncropped print's centre,
// -100..100 (negative darkens the corners). The Mac draws this one slider in
// Pre-Dev's Camera section (CameraSection.swift:82-85, "where a photographer
// looks for it") although it is Post-Dev's; here it sits with the rest of the
// grade. The midpoint is stored (50) but, as on the Mac, has no slider.
MacSection {
    sectionId: "postDev.vignette"
    title: L10n.tr("postDev.vignetting")
    defaultExpanded: true
    divider: false
    resetVisible: true
    resetAvailable: preview.settingsEditable && preview.hasFrame
    resetToolTip: L10n.tr("postDev.resetVignetting")
    onResetRequested: preview.resetPostDev("vignette")

    PostDevSlider { objectName: "postDevVignette"; path: "vignette.amount"; label: L10n.tr("postDev.amount") }
    Note { text: L10n.tr("postDev.vignettingNote") }
}
