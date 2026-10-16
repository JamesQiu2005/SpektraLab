import QtQuick
import QtQuick.Layouts

// A plot's ground with nothing measured on it yet: the Latitude graph and the
// Tone Mask curve keep their place and their size on the rail, and say in
// words what will be drawn there, so a later lane replaces the inside of the
// well and not the layout around it.
Rectangle {
    property string text
    Layout.fillWidth: true
    implicitHeight: Theme.plotHeight
    radius: 2
    color: Theme.plot
    Rectangle { x: parent.width / 2; width: 1; height: parent.height; color: Theme.plotGrid }
    Rectangle { y: parent.height / 2; height: 1; width: parent.width; color: Theme.plotGrid }
    Text {
        anchors.centerIn: parent
        width: parent.width - 16
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: parent.text
        color: Theme.dim
        font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
        style: Text.Outline; styleColor: Theme.plot
    }
}
