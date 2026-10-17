import QtQuick
import QtQuick.Controls

// A text field drawn as the page's pill (ExportPage.swift's Subfolder and Long
// Edge fields: a ground-coloured capsule, the label face, committed on Return
// or on leaving the field).
//
//   text           the model's value (bind it)
//   placeholder    shown while empty ("none")
//   numeric        digits only, centred
//   keepsDraft     keep the typed text after committing (a dialog's draft,
//                  read when the dialog is accepted) rather than going back
//                  to modelText
//   committed(text)  the user's new value, on Return or focus loss
TextField {
    id: field
    property string placeholder
    property bool numeric: false
    property bool keepsDraft: false
    property string modelText
    signal committed(string value)
    text: modelText
    onModelTextChanged: if (!activeFocus) text = modelText
    implicitHeight: Theme.controlHeight
    leftPadding: 9; rightPadding: 9; topPadding: 0; bottomPadding: 0
    verticalAlignment: TextInput.AlignVCenter
    horizontalAlignment: numeric ? TextInput.AlignHCenter : TextInput.AlignLeft
    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
    color: Theme.text
    placeholderText: placeholder
    placeholderTextColor: Theme.dim
    selectByMouse: true
    validator: numeric ? digits : null
    readonly property IntValidator digits: IntValidator { bottom: 0; top: 60000 }
    background: Rectangle {
        radius: height / 2
        color: Theme.pill
        border.width: field.activeFocus ? 1 : 0
        border.color: Theme.accent
    }
    onEditingFinished: {
        committed(text)
        if (!keepsDraft) text = Qt.binding(function() { return field.modelText })
    }
}
