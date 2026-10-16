import QtQuick
import QtQuick.Layouts

// The status line under the canvas: the frame's size, what the canvas shows,
// and whether a preview update is pending.
Rectangle {
    Layout.fillWidth: true; implicitHeight: 28; color: Theme.card
    Text {
        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; verticalAlignment: Text.AlignVCenter
        text: preview.hasFrame ? preview.metadata.width + " × " + preview.metadata.height + "   ·   " + L10n.tr("statusBar.previewFormat") + "   ·   " + (preview.dirty ? L10n.tr("statusBar.updating") : L10n.tr("statusBar.autoApply")) : L10n.tr("statusBar.fullResolution")
        color: preview.dirty ? Theme.accent : Theme.muted; font.pixelSize: 10; elide: Text.ElideRight
    }
}
