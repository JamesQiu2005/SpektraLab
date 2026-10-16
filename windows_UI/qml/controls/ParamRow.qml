import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// One control row on a rail: a label column (with an optional dim second
// line under the label -- "stops", "← blue", "As Shot") and the control after
// it. ScrubSlider, CheckRow and the pill rows are built on it; a section can
// also put any control in one directly:
//
//   ParamRow { label: L10n.tr("camera.metering"); PillDropdown { ... } }
//
//   label, sublabel    the two lines of the label column
//   secondLine         items for the second line instead of `sublabel`
//   labelWidth         the column; by default the nearest ancestor's
//                      `railLabelWidth` (the Parameters rail sets its wider
//                      grid once, as the Mac's environment does), else
//                      Theme.labelWidth. A longer label widens its own row
//                      rather than truncating (the Mac: "a column, not a cage").
//   available, reason  false greys the whole row -- label and control, the
//                      Mac's one rule -- refuses input and shows `reason` on
//                      hover; `toolTip` is the hover text while available
//   bodyObjectName     objectName of the inner item whose `enabled` is
//                      `available` (the --self-test reads "exposureSlider")
//   control            (default) the control, laid out in the slot after the
//                      label column, `Theme.rowHeight` tall
Item {
    id: row
    property string label
    property string sublabel
    property alias secondLine: secondSlot.data
    property real labelWidth: {
        for (var p = parent; p; p = p.parent)
            if (p.railLabelWidth !== undefined) return p.railLabelWidth
        return Theme.labelWidth
    }
    property bool available: true
    property string reason
    property string toolTip
    property alias bodyObjectName: body.objectName
    default property alias control: slot.data
    readonly property bool hasSecondLine: sublabel.length > 0 || secondSlot.children.length > 0
    readonly property real controlX: Math.max(labelWidth, labelText.implicitWidth + 6)

    Layout.fillWidth: true
    implicitWidth: controlX + 120
    implicitHeight: Theme.rowHeight + (hasSecondLine ? Theme.subRowHeight : 0)
    opacity: available ? 1 : Theme.disabledOpacity

    Item {
        id: body
        anchors.fill: parent
        enabled: row.available
        Text {
            id: labelText
            y: 0; height: Theme.rowHeight
            verticalAlignment: Text.AlignVCenter
            text: row.label
            color: Theme.secondaryText
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel; font.weight: Theme.weightText
        }
        Text {
            y: Theme.rowHeight - 2; height: Theme.subRowHeight
            width: row.controlX - 4
            visible: row.sublabel.length > 0 && secondSlot.children.length === 0
            verticalAlignment: Text.AlignTop
            text: row.sublabel
            elide: Text.ElideRight
            color: Theme.dim
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
        }
        Item {
            id: secondSlot
            y: Theme.rowHeight - 3; height: Theme.subRowHeight + 2
            width: row.controlX
        }
        Item {
            id: slot
            x: row.controlX; y: 0
            width: row.width - row.controlX; height: Theme.rowHeight
        }
    }
    HoverHandler { id: hover }
    readonly property string hint: row.available ? row.toolTip : row.reason
    ToolTip.visible: hover.hovered && hint.length > 0
    ToolTip.text: hint
    ToolTip.delay: 600
}
