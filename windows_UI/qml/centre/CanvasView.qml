import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import SpektraLab.Native 1.0

// The canvas (EditorWindow.swift `CanvasArea`) on the ground grey, with what
// is drawn over it: the crop editor, the empty state, the drop target for RAW
// files, and the badge stack in the top-right corner. The canvas keeps the
// objectName "frameCanvas" the --self-test looks up, and fills the area as
// the Mac's does: a fitted frame meets the canvas's edges, and the ground
// shows only on the other axis.
//
// The badge stack is the Mac's: the output histogram heads it (a later lane;
// `histogramSlot` is where it goes, 200 x 56 on the Mac), then the badges as
// plain text with a shadow -- "full" for the frame at its own resolution,
// "uncropped" while the crop editor shows the whole source. Nothing in the
// stack takes the mouse.
Item {
    id: view
    required property EditorState editor
    readonly property FrameCanvas canvas: frameCanvas
    Layout.fillWidth: true; Layout.fillHeight: true
    clip: true

    FrameCanvas {
        id: frameCanvas
        objectName: "frameCanvas"
        anchors.fill: parent
        image: view.editor.cropMode ? preview.uncroppedImage : preview.previewImage
        enabled: !view.editor.cropMode
    }
    CropOverlay { canvas: frameCanvas; editor: view.editor }
    Column {
        anchors.centerIn: parent
        spacing: 10
        visible: !preview.hasFrame
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: L10n.tr("app.name")
            color: Theme.text
            font.family: Theme.fontFamily; font.pixelSize: 30; font.weight: Font.Light
            font.letterSpacing: 1
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: L10n.tr("canvas.emptyHint")
            color: Theme.secondaryText
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel; font.weight: Theme.weightText
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: L10n.tr("canvas.dropHint")
            color: "#c9c7c2"
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
        }
    }
    DropArea {
        anchors.fill: parent
        enabled: view.editor.canBrowse
        onDropped: function(drop) { if (drop.hasUrls) preview.openFiles(drop.urls) }
    }
    // The filmstrip's tab (CollapseTab.swift `HoverEdgeTab`): a small pill on
    // the canvas's lower edge that appears when the pointer comes near it.
    Item {
        id: stripEdge
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        height: 36
        HoverHandler { id: edgeHover }
        Rectangle {
            id: stripTab
            anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom
            anchors.bottomMargin: 4
            width: 42; height: 14; radius: 7
            visible: edgeHover.hovered || view.editor.filmstripCollapsed
            color: tabMouse.containsMouse ? "#d0383837" : "#b02d2d2c"
            Text {
                anchors.centerIn: parent
                text: view.editor.filmstripCollapsed ? Icons.chevronUp : Icons.chevronDown
                font.family: Theme.iconFamily; font.pixelSize: 8
                color: Theme.text
            }
            MouseArea {
                id: tabMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: view.editor.filmstripCollapsed = !view.editor.filmstripCollapsed
            }
            ToolTip.visible: tabMouse.containsMouse
            ToolTip.text: view.editor.filmstripCollapsed ? L10n.tr("canvas.showFilmstrip") : L10n.tr("canvas.hideFilmstrip")
            ToolTip.delay: 500
        }
    }
    Column {
        anchors.right: parent.right; anchors.top: parent.top
        anchors.margins: 8
        spacing: 4
        visible: preview.hasFrame
        Item { objectName: "histogramSlot"; width: 200; height: 0; anchors.right: parent.right }
        Text {
            anchors.right: parent.right
            text: view.editor.cropMode ? L10n.tr("canvas.badge.uncropped") : L10n.tr("canvas.badge.full")
            color: Theme.text
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightTitle
            style: Text.Raised; styleColor: "#99000000"
        }
    }
}
