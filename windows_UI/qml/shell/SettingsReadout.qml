import QtQuick
import QtQuick.Layouts

// A label and a value that is read, not set (SettingsWindow.swift
// `readout`): the label in the metadata ink in a fixed column, the value in
// the text ink, wrapping -- a path is shown whole, never "...\SpektraLab".
//
//   label, value
//   warning    the value in the warning ink (a failure, a fallback)
//   selectable the value can be selected and copied (paths, build strings)
RowLayout {
    id: readout
    property string label
    property string value
    property bool warning: false
    property bool selectable: false
    Layout.fillWidth: true
    spacing: 6

    Text {
        Layout.preferredWidth: 110
        Layout.alignment: Qt.AlignTop
        text: readout.label
        color: Theme.dim
        elide: Text.ElideRight
        font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
    }
    TextEdit {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignTop
        text: readout.value
        readOnly: true
        selectByMouse: readout.selectable
        activeFocusOnPress: readout.selectable
        wrapMode: TextEdit.WrapAnywhere
        color: readout.warning ? Theme.warning : Theme.text
        selectionColor: Theme.accent
        selectedTextColor: Theme.selectionInk
        font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
    }
}
