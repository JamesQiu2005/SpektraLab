import QtQuick
import QtQuick.Controls

// A glyph button: the tool bar's tools, a section header's reset and "...",
// the crop section's turns and flips, the filmstrip's chevrons.
//
//   glyph        a code point from Icons.qml
//   glyphSize    ink size in px (the Mac's 16 on the bar, ~10 in a header)
//   active       tints the glyph with the accent -- a selected tool or an
//                engaged flip (the Mac's rule: selection is orange, not a plate)
//   dimmed       a live control in the secondary ink, as the Mac draws an
//                unselected tool
//   mirrored, glyphRotation   for a glyph that serves two directions
//   available    false greys the glyph and refuses the click; `reason` is
//                then the tooltip, so a control that is not wired yet says why
//   toolTip      hover text while available
//   clicked()    emitted by a click while available
//   buttonObjectName   the objectName of the inner AbstractButton, whose
//                `enabled` is `available` and whose `clicked` is this
//                signal -- what the --self-test finds and invokes for
//                "undoButton" / "redoButton".
//
// The root stays enabled so it can show a tooltip over a disabled glyph (a
// disabled item takes no hover). The target is `size` square whatever the
// ink, and Windows gets a faint hover plate the Mac does not draw: a pointer
// target with no hover response reads as dead here.
Item {
    id: root
    property string glyph
    property int glyphSize: Theme.toolGlyph
    property bool active: false
    property bool dimmed: false
    property bool mirrored: false
    property real glyphRotation: 0
    property bool available: true
    property string reason
    property string toolTip
    property int size: Theme.toolButton
    property alias buttonObjectName: button.objectName
    readonly property bool hovered: hover.hovered
    signal clicked()
    implicitWidth: size; implicitHeight: size

    AbstractButton {
        id: button
        anchors.fill: parent
        enabled: root.available
        focusPolicy: Qt.NoFocus
        padding: 0
        onClicked: root.clicked()
        background: Rectangle {
            radius: 4
            color: button.down ? "#24ffffff" : hover.hovered && button.enabled ? Theme.hover : "transparent"
        }
        contentItem: Text {
            text: root.glyph
            font.family: Theme.iconFamily
            font.pixelSize: root.glyphSize
            color: root.active ? Theme.accent : root.dimmed ? Theme.secondaryText : Theme.text
            opacity: button.enabled ? 1 : 0.4
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            transform: [
                Scale { origin.x: root.width / 2; xScale: root.mirrored ? -1 : 1 },
                Rotation { origin.x: root.width / 2; origin.y: root.height / 2; angle: root.glyphRotation }
            ]
        }
    }
    HoverHandler { id: hover }
    readonly property string hint: root.available ? root.toolTip : root.reason
    ToolTip.visible: hover.hovered && hint.length > 0
    ToolTip.text: hint
    ToolTip.delay: 500
}
