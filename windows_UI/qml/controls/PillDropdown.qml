import QtQuick
import QtQuick.Controls

// The menu pill (FormatPicker.swift `PillMenu`): a ground-coloured capsule
// with the current choice and the hollow triangle, opening a dark list with
// a check on the current choice. A ComboBox underneath, so keyboard, wheel
// and accessibility are Qt's.
//
//   model, currentIndex, displayText, activated(index)   ComboBox's own.
//     A model built from L10n.tr() must be read by the currentIndex binding
//     (`currentIndex: { model; return ... }`, i18n/README.md): a language
//     switch replaces the model and resets the index.
//   fill        true: the pill takes the whole slot (Metering, Aspect);
//               false: Theme.pickerWidth at the slot's trailing edge (Size,
//               Side), the Mac's two shapes
//   available, reason, toolTip   greying and hover text, as ParamRow; put the
//               pill in a ParamRow and set them there to grey the label too
ComboBox {
    id: pill
    property bool fill: true
    property bool available: true
    property string reason
    property string toolTip
    enabled: available
    implicitHeight: Theme.controlHeight
    implicitWidth: fill ? 120 : Theme.pickerWidth
    // Placement in a ParamRow's slot; a Layout that holds the pill instead
    // overrides all three.
    width: parent && fill ? parent.width : implicitWidth
    x: parent && !fill ? parent.width - width : 0
    y: parent ? (parent.height - height) / 2 : 0
    font.family: Theme.fontFamily
    font.pixelSize: Theme.fontSmall
    font.weight: Theme.weightText
    hoverEnabled: true
    leftPadding: 10; rightPadding: 22
    topPadding: 0; bottomPadding: 0
    opacity: available ? 1 : Theme.disabledOpacity

    background: Rectangle {
        radius: height / 2
        color: pill.hovered && pill.enabled ? "#686866" : Theme.pill
        border.width: pill.visualFocus ? 1 : 0
        border.color: Theme.accent
    }
    contentItem: Text {
        text: pill.displayText
        font: pill.font
        color: Theme.text
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
    indicator: Triangle {
        x: pill.width - width - 9
        anchors.verticalCenter: parent.verticalCenter
        width: 8; height: 5; lineWidth: 1
    }
    delegate: ItemDelegate {
        id: entry
        required property int index
        width: pill.popup.width - pill.popup.leftPadding - pill.popup.rightPadding
        height: 24
        leftPadding: 26
        // The style's 8 px vertical padding would leave the label an 8 px box,
        // and an eliding Text shows no line that does not fit its height.
        topPadding: 0; bottomPadding: 0
        highlighted: pill.highlightedIndex === index
        // The entry's title through the ComboBox's own text lookup, which
        // handles a string list and a textRole model alike.
        text: pill.textAt(index)
        contentItem: Text {
            text: entry.text
            font: pill.font
            color: Theme.text
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        Text {
            x: 8; anchors.verticalCenter: parent.verticalCenter
            visible: entry.index === pill.currentIndex
            text: Icons.check
            font.family: Theme.iconFamily; font.pixelSize: 11
            color: Theme.accent
        }
        background: Rectangle { radius: 4; color: entry.highlighted ? "#3b3b39" : "transparent" }
    }
    popup: Popup {
        y: pill.height + 2
        width: Math.max(pill.width, 160)
        implicitHeight: Math.min(contentItem.implicitHeight + topPadding + bottomPadding, 420)
        padding: 4
        contentItem: ListView {
            clip: true
            implicitHeight: contentHeight
            model: pill.popup.visible ? pill.delegateModel : null
            currentIndex: pill.highlightedIndex
            ScrollIndicator.vertical: ScrollIndicator {}
        }
        background: Rectangle { color: "#262625"; border.color: Theme.ruleRegion; radius: 6 }
    }
    HoverHandler { id: hover }
    readonly property string hint: pill.available ? pill.toolTip : pill.reason
    ToolTip.visible: hover.hovered && hint.length > 0
    ToolTip.text: hint
    ToolTip.delay: 600
}
