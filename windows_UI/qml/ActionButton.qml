import QtQuick
import QtQuick.Controls

// A labelled push button for the places a capsule glyph is not enough: the
// export options' actions, the status section's Stop / Retry. Drawn as the
// rail's filled capsule (PillButton's shape) with a Button underneath, so it
// keeps Button's API -- `text`, `clicked`, keyboard activation -- for the
// panes and tests written against it. `accented` outlines it in the accent:
// the default action, or a mode that is on.
Button {
    id: root
    property bool accented: false
    padding: 6
    leftPadding: 14; rightPadding: 14
    implicitHeight: 24
    font.family: Theme.fontFamily
    font.pixelSize: Theme.fontSmall
    font.weight: Theme.weightText
    hoverEnabled: true
    contentItem: Text {
        text: root.text
        color: root.accented ? Theme.accent : Theme.text
        opacity: root.enabled ? 1 : Theme.disabledOpacity
        font: root.font
        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
    background: Rectangle {
        radius: height / 2
        color: root.down ? "#727270" : root.hovered && root.enabled ? "#686866" : Theme.pill
        opacity: root.enabled ? 1 : Theme.disabledOpacity
        border.width: root.accented || root.visualFocus ? 1 : 0
        border.color: Theme.accent
    }
}
