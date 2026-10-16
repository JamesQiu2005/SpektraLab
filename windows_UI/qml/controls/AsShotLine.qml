import QtQuick

// "As Shot" and its box, on the second line of a slider row under the label
// (CameraSection.swift `AsShotLine`): Film Exposure, Temperature and Tint
// each have one. Put it in a ParamRow / ScrubSlider's `secondLine`.
//
//   checked, toggledTo(on), available, reason   as SquareCheck
Row {
    id: line
    property bool checked: false
    property bool available: true
    property string reason
    signal toggledTo(bool on)
    spacing: 2
    Text {
        anchors.verticalCenter: parent.verticalCenter
        text: L10n.tr("camera.asShot")
        color: Theme.dim
        opacity: line.available ? 1 : Theme.disabledOpacity
        font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
    }
    SquareCheck {
        anchors.verticalCenter: parent.verticalCenter
        height: 16
        checked: line.checked
        available: line.available
        reason: line.reason
        onToggledTo: function(on) { line.toggledTo(on) }
    }
}
