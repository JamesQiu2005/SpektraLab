import QtQuick
import QtQuick.Layouts

// Secondary copy under a control: muted, small, wrapping to the rail's width.
Text {
    Layout.fillWidth: true
    color: Theme.muted
    font.pixelSize: 10
    wrapMode: Text.WordWrap
    lineHeight: 1.35
}
