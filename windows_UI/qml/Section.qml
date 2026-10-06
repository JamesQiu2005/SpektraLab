import QtQuick
import QtQuick.Layouts
ColumnLayout {
    id: root
    property string title
    default property alias content: rows.data
    Layout.fillWidth: true
    spacing: 10
    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line; opacity: 0.55 }
    Text { text: root.title; color: Theme.text; font.pixelSize: 13; font.bold: true; Layout.leftMargin: 14; Layout.topMargin: 2 }
    ColumnLayout { id: rows; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.bottomMargin: 12; spacing: 8 }
}
