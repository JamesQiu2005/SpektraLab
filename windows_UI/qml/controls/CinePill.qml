import QtQuick

// The CINE mark after a cinema stock (FormatPicker.swift `CinePill`): an
// accent outline and accent letters, no plate. On a selected (white) row it
// takes the row's near-black ink instead, so the badge inverts with the name.
Rectangle {
    property bool inverted: false
    implicitWidth: Theme.cinePillWidth; implicitHeight: Theme.cinePillHeight
    radius: height / 2
    color: "transparent"
    border.width: 1
    border.color: inverted ? Theme.selectionInk : Theme.accent
    Text {
        anchors.centerIn: parent
        text: "CINE"
        color: parent.inverted ? Theme.selectionInk : Theme.accent
        font.family: Theme.fontFamily; font.pixelSize: Theme.fontCine; font.weight: Theme.weightTitle
    }
}
