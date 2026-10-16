import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The left rail, "Film and Print": its title over the scrolling stack of the
// darkroom sections, top to bottom in the order the rail draws them.
Rectangle {
    id: rail
    required property EditorState editor
    Layout.preferredWidth: Theme.leftWidth; Layout.fillHeight: true; color: Theme.card
    ColumnLayout {
        anchors.fill: parent; spacing: 0
        Text { text: "胶片与相纸"; color: Theme.text; font.pixelSize: 14; font.bold: true; Layout.leftMargin: 14; Layout.preferredHeight: Theme.topHeight; verticalAlignment: Text.AlignVCenter }
        ScrollView {
            Layout.fillWidth: true; Layout.fillHeight: true; clip: true; contentWidth: availableWidth
            ColumnLayout {
                width: parent.width; spacing: 0
                NavigatorSection { editor: rail.editor }
                FilmSection {}
                PrintSection {}
                CropSection { editor: rail.editor }
                EnlargerSection {}
            }
        }
    }
}
