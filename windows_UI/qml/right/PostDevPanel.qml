import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The Parameters rail's Post-Dev side (RightSections.swift, the 2026-09-17
// drawing's order): White Balance, Exposure, Curve, Color Balance -- all
// Layer 2, the grade on the finished print, never sent to the engine. Its
// vignette is the Camera section's Vignetting row, where the Mac keeps it
// (CameraSection.swift:82-85) and nowhere else. Each edit
// re-grades the canvas at once on the GPU (FrameCanvas postDev), is saved with
// the photograph and is one undo step; Sync and the clipboard do not copy it
// (SettingsClipboard.swift). While the grade is bypassed (Ctrl+Shift+B, the
// application menu) a line at the top says so, because a bypass you forgot
// you turned on looks like a broken render (SpektrafilmApp.swift:167-170).
ScrollView {
    id: scroll
    objectName: "postDevPanel"
    Layout.fillWidth: true; Layout.fillHeight: true
    clip: true
    contentWidth: availableWidth
    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
    ScrollBar.vertical: RailScrollBar { parent: scroll; x: scroll.width - width; height: scroll.availableHeight }
    ColumnLayout {
        width: scroll.availableWidth
        spacing: 0
        Item {
            visible: preview.hasFrame && !preview.postDevEnabled
            Layout.fillWidth: true
            Layout.preferredHeight: bypassNote.implicitHeight + 12
            Text {
                id: bypassNote
                objectName: "postDevBypassNote"
                x: Theme.rowInset; width: parent.width - 2 * Theme.rowInset
                anchors.verticalCenter: parent.verticalCenter
                text: L10n.tr("postDev.bypassed")
                color: Theme.accent
                wrapMode: Text.WordWrap
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
            }
        }
        PostDevWhiteBalanceSection {}
        PostDevExposureSection {}
        PostDevCurveSection {}
        PostDevColorBalanceSection { divider: false }
    }
}
