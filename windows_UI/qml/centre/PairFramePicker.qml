import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import SpektraLab.Native 1.0

// Add Frame / Replace Frame (PairSection.swift PairFramePicker): the open
// folder's photographs, drawn as the filmstrip draws them, with a name
// filter. A frame already in this pair is dimmed and marked; it can still be
// chosen (the same frame twice is allowed). Choosing puts it in `side`.
Popup {
    id: picker
    property string side: "first"
    function openFor(s) { side = s; filter.text = ""; open(); filter.forceActiveFocus() }

    parent: Overlay.overlay
    x: Math.round((parent.width - width) / 2)
    y: Math.round((parent.height - height) / 2)
    width: 4 * 96 + 3 * 8 + 24
    padding: 12
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: Rectangle { color: Theme.card; radius: 8; border.color: Theme.ruleRegion; border.width: 1 }

    readonly property var shown: {
        var all = preview.pair.candidates || [], f = filter.text.trim().toLowerCase(), out = []
        for (var i = 0; i < all.length; ++i) if (f.length === 0 || all[i].name.toLowerCase().indexOf(f) >= 0) out.push(all[i])
        return out
    }

    contentItem: ColumnLayout {
        spacing: 8
        TextField {
            id: filter
            objectName: "pairPickerFilter"
            Layout.fillWidth: true
            placeholderText: L10n.tr("pair.filter")
            color: Theme.text
            placeholderTextColor: Theme.dim
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel
            background: Rectangle { radius: 6; color: Theme.well }
        }
        GridView {
            id: grid
            Layout.fillWidth: true
            Layout.preferredHeight: 300
            clip: true
            cellWidth: 104; cellHeight: 96
            model: picker.shown
            ScrollBar.vertical: ScrollBar {}
            delegate: Item {
                id: cell
                required property var modelData
                width: 96; height: 92
                Rectangle {
                    id: well
                    width: 96; height: 72
                    radius: 2
                    color: Theme.well
                    opacity: cell.modelData.used ? 0.45 : 1
                    Loader {
                        anchors.fill: parent
                        active: cell.modelData.thumbnail !== undefined
                        sourceComponent: FrameCanvas { image: cell.modelData.thumbnail; enabled: false }
                    }
                    border.width: cellMouse.containsMouse ? 1 : 0
                    border.color: Theme.selectionFrame
                }
                Text {
                    anchors.top: well.bottom; anchors.topMargin: 3
                    width: 96
                    horizontalAlignment: Text.AlignHCenter
                    text: cell.modelData.used ? L10n.tr("pair.inThisPair") : cell.modelData.name
                    elide: Text.ElideMiddle
                    color: Theme.dim
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
                }
                MouseArea {
                    id: cellMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { preview.setPairFrame(picker.side, cell.modelData.index); picker.close() }
                }
                ToolTip.visible: cellMouse.containsMouse
                ToolTip.text: cell.modelData.name
                ToolTip.delay: 600
            }
        }
        Text {
            visible: picker.shown.length === 0
            Layout.fillWidth: true
            text: L10n.tr("pair.noCandidates")
            color: Theme.dim
            wrapMode: Text.WordWrap
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta
        }
    }
}
