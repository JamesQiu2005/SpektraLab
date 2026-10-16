import QtQuick
import QtQuick.Controls

// One row of a RailMenu: the label in the label face, a check mark for a
// checkable item that is on (the Mac's checkmark in a pill menu), a grey
// hover plate rather than a system blue. Disabled rows keep
// their place at the rail's disabled opacity, so a menu can list what is
// coming without pretending it works.
MenuItem {
    id: item
    // A check drawn without making the item checkable: a checkable item
    // toggles itself on a click and loses its binding to the state it shows.
    property bool marked: false
    implicitHeight: 24
    implicitWidth: leftPadding + label.implicitWidth + rightPadding
    leftPadding: 26; rightPadding: 16
    // The row is 24 px; the label is vertically centred in all of it (an
    // eliding Text shows no line that does not fit its height).
    topPadding: 0; bottomPadding: 0
    font.family: Theme.fontFamily
    font.pixelSize: Theme.fontLabel
    font.weight: Theme.weightText
    contentItem: Text {
        id: label
        text: item.text
        font: item.font
        color: Theme.text
        opacity: item.enabled ? 1 : Theme.disabledOpacity
        elide: Text.ElideRight
        verticalAlignment: Text.AlignVCenter
    }
    indicator: Text {
        x: 8; anchors.verticalCenter: parent.verticalCenter
        visible: item.checked || item.marked
        text: Icons.check
        font.family: Theme.iconFamily
        font.pixelSize: 11
        color: Theme.accent
    }
    arrow: Text {
        x: item.width - width - 6; anchors.verticalCenter: parent.verticalCenter
        visible: item.subMenu !== null
        text: Icons.chevronRight
        font.family: Theme.iconFamily
        font.pixelSize: 9
        color: Theme.secondaryText
    }
    background: Rectangle {
        radius: 4
        color: item.highlighted && item.enabled ? "#3b3b39" : "transparent"
    }
}
