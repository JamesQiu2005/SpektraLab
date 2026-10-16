import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The right rail, "Parameters · Pre-Dev": its title over the scrolling stack
// of the pre-development sections, top to bottom in the order drawn.
Rectangle {
    id: rail
    required property EditorState editor
    Layout.preferredWidth: Theme.rightWidth; Layout.fillHeight: true; color: Theme.card
    ColumnLayout {
        anchors.fill: parent; spacing: 0
        Text { text: L10n.tr("rail.parametersPreDev"); color: Theme.text; font.pixelSize: 14; font.bold: true; Layout.leftMargin: 14; Layout.preferredHeight: Theme.topHeight; verticalAlignment: Text.AlignVCenter }
        ScrollView {
            Layout.fillWidth: true; Layout.fillHeight: true; clip: true; contentWidth: availableWidth
            ColumnLayout {
                width: parent.width; spacing: 0
                CameraSection {}
                FilmFormatSection {}
                DecodeSection {}
                InfoSection {}
                StatusSection { editor: rail.editor }
            }
        }
    }
}
