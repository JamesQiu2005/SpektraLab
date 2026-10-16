import QtQuick
import QtQuick.Controls

// One choice among a few, as one control (SegmentedSwitch.swift): a track in
// the plot colour and a white thumb with near-black ink on the chosen side --
// the stock lists' selection language -- the other sides in the secondary
// ink. The accent stays with actions and state.
//
//   model            the sides' titles
//   currentIndex     the chosen side (bind it)
//   optionEnabled    per side, true when absent; a disabled side greys and
//                    takes no click
//   optionToolTips   per side: the reason a side is disabled, or its help
//   activated(index) the user chose another side
Item {
    id: control
    property var model: []
    property int currentIndex: 0
    property var optionEnabled: []
    property var optionToolTips: []
    // The narrowest a side may be, so two titles of different lengths still
    // make two equal halves (the Mac's 83.5 px tabs, less a little).
    property real sideWidth: 72
    signal activated(int index)
    readonly property int inset: 2
    implicitHeight: 22
    implicitWidth: row.implicitWidth + 2 * inset

    function sideEnabled(i) { return optionEnabled.length <= i || optionEnabled[i] !== false }

    Rectangle { anchors.fill: parent; radius: height / 2; color: Theme.plot }
    Row {
        id: row
        x: control.inset; y: control.inset
        height: control.height - 2 * control.inset
        Repeater {
            model: control.model
            delegate: Item {
                id: side
                required property var modelData
                required property int index
                readonly property bool chosen: index === control.currentIndex
                readonly property bool usable: control.sideEnabled(index)
                width: Math.max(label.implicitWidth + 20, control.sideWidth)
                height: row.height
                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    visible: side.chosen
                    color: Theme.selection
                }
                Text {
                    id: label
                    anchors.centerIn: parent
                    text: side.modelData
                    color: side.chosen ? Theme.selectionInk : Theme.secondaryText
                    opacity: side.usable ? 1 : Theme.disabledOpacity
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel; font.weight: Theme.weightText
                }
                MouseArea {
                    anchors.fill: parent
                    enabled: side.usable && !side.chosen
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: control.activated(side.index)
                }
                HoverHandler { id: sideHover }
                readonly property string hint: control.optionToolTips.length > side.index ? control.optionToolTips[side.index] : ""
                ToolTip.visible: sideHover.hovered && hint.length > 0
                ToolTip.text: hint
                ToolTip.delay: 400
            }
        }
    }
}
