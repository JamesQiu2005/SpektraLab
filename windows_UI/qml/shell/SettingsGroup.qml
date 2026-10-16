import QtQuick
import QtQuick.Layouts

// One group on a Settings page (SettingsWindow.swift `SettingsGroup` and
// `SettingsRows`): a small grey title, a hairline to the edge, and the rows
// under it at the rail's inset. Not collapsible -- a settings page is read,
// not worked in.
//
//   title      the group's title
//   content    (default) the rows: ParamRow, CheckRow, Note, SettingsReadout
ColumnLayout {
    id: group
    property string title
    default property alias content: rows.data
    Layout.fillWidth: true
    spacing: 0

    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: Theme.rowInset; Layout.rightMargin: Theme.rowInset
        Layout.topMargin: 4
        spacing: 8
        Text {
            text: group.title
            color: Theme.dim
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Font.Bold
        }
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.rule }
    }
    ColumnLayout {
        id: rows
        Layout.fillWidth: true
        Layout.leftMargin: Theme.rowInset; Layout.rightMargin: Theme.rowInset
        Layout.topMargin: 6; Layout.bottomMargin: 6
        spacing: Theme.rowSpacing
    }
}
