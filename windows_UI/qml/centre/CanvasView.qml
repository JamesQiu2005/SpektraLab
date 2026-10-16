import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes
import SpektraLab.Native 1.0

// The canvas (EditorWindow.swift `CanvasArea`) on the ground grey, with what
// is drawn over it: the before/after split, the crop editor, the empty state,
// the drop target for RAW files, and the badge stack in the top-right corner.
// The canvas keeps the objectName "frameCanvas" the --self-test looks up, and
// fills the area as the Mac's does: a fitted frame meets the canvas's edges,
// and the ground shows only on the other axis.
//
// Every picture is a FrameCanvas, so the print, the Original and the split's
// left half all go through the window's display LUT; the line, the grip, the
// labels and the histogram are chrome, drawn over it unmanaged (AGENTS.md
// trap 27). What the canvas shows:
//   crop editor       the uncropped source (uncroppedImage)
//   Original          the decode, cropped and turned like the print, while the
//                     pill is on or Space is held (TopBar.swift, keyDown 49)
//   before / after    the Original left of the split, the print right of it
//                     (CompareOverlay.swift); Space wins over the split
//   otherwise         the print (previewImage)
//
// The badge stack is the Mac's: the histogram heads it -- 200 x 56, no ground,
// on a soft dark haze -- then the badges as plain text with a shadow. The
// histogram describes what the canvas shows: the *cropped* print (the Mac's
// counts the uncropped print, a known Mac bug -- AGENTS.md trap 33), the whole
// source in the crop editor, the Original while it is shown. Nothing in the
// stack takes the mouse.
Item {
    id: view
    required property EditorState editor
    readonly property FrameCanvas canvas: frameCanvas
    Layout.fillWidth: true; Layout.fillHeight: true
    clip: true

    readonly property bool showOriginal: editor.showingOriginal && preview.originalReady
    readonly property bool splitShown: editor.comparing && preview.originalReady && !editor.showingOriginal && !editor.cropMode
    readonly property rect picture: frameCanvas.imageRect
    readonly property real splitX: picture.x + editor.comparePosition * picture.width

    // The grip's two filled arrowheads (CompareOverlay.swift arrowtriangle).
    component Arrow: Shape {
        id: arrow
        property bool pointsRight: true
        width: 5; height: 7
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeWidth: -1; strokeColor: "transparent"; fillColor: Theme.selectionFrame
            startX: arrow.pointsRight ? 0 : 5; startY: 0
            PathLine { x: arrow.pointsRight ? 5 : 0; y: 3.5 }
            PathLine { x: arrow.pointsRight ? 0 : 5; y: 7 }
            PathLine { x: arrow.pointsRight ? 0 : 5; y: 0 }
        }
    }

    FrameCanvas {
        id: frameCanvas
        objectName: "frameCanvas"
        anchors.fill: parent
        image: view.editor.cropMode ? preview.uncroppedImage : view.showOriginal ? preview.originalImage : preview.previewImage
        interactive: !view.editor.cropMode
    }
    // The split's left half: the Original in exactly the print's rectangle,
    // clipped at the line.
    Item {
        id: before
        visible: view.splitShown
        x: 0; y: 0; height: parent.height
        width: Math.max(0, Math.min(parent.width, view.splitX))
        clip: true
        FrameCanvas {
            objectName: "beforeCanvas"
            width: view.width; height: view.height
            image: preview.originalImage
            follow: frameCanvas
            enabled: false
        }
    }
    CropOverlay { canvas: frameCanvas; editor: view.editor }
    // The split's furniture: the line, the grip and the two labels. The line
    // and grip take the drag; the rest of the canvas keeps its pan.
    Item {
        id: compareChrome
        objectName: "compareOverlay"
        anchors.fill: parent
        visible: view.splitShown
        readonly property real lineTop: Math.max(0, Math.min(height, view.picture.y))
        readonly property real lineBottom: Math.max(0, Math.min(height, view.picture.y + view.picture.height))
        Rectangle { x: view.splitX - 1; y: compareChrome.lineTop; width: 3; height: compareChrome.lineBottom - compareChrome.lineTop; color: "#59000000" }
        Rectangle { x: view.splitX - 0.5; y: compareChrome.lineTop; width: 1; height: compareChrome.lineBottom - compareChrome.lineTop; color: Theme.selectionFrame }
        Rectangle {
            id: grip
            width: 30; height: 30; radius: 15
            x: view.splitX - 15; y: (compareChrome.lineTop + compareChrome.lineBottom) / 2 - 15
            color: Qt.rgba(0.176, 0.176, 0.173, 0.55)
            border.color: Theme.selectionFrame; border.width: 1
            Row {
                anchors.centerIn: parent; spacing: 2
                Arrow { pointsRight: false }
                Arrow { pointsRight: true }
            }
        }
        // In the picture's top corners (CompareOverlay.swift): "After" drops
        // below the badge stack when the picture reaches the canvas's right edge.
        Label {
            readonly property real edge: Math.max(view.picture.x, 0) + 12
            visible: view.splitX - edge > 24 + width
            x: edge; y: compareChrome.lineTop + 8
            text: L10n.tr("canvas.before")
            color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightTitle
            leftPadding: 6; rightPadding: 6; topPadding: 2; bottomPadding: 2
            background: Rectangle { radius: height / 2; color: Qt.rgba(0.176, 0.176, 0.173, 0.8) }
        }
        Label {
            id: afterLabel
            readonly property real edge: Math.min(view.picture.x + view.picture.width, view.width) - 12
            visible: edge - view.splitX > 24 + width
            x: edge - width
            y: view.width - edge < 220 ? Math.max(compareChrome.lineTop + 8, badges.y + badges.height + 4) : compareChrome.lineTop + 8
            text: L10n.tr("canvas.after")
            color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightTitle
            leftPadding: 6; rightPadding: 6; topPadding: 2; bottomPadding: 2
            background: Rectangle { radius: height / 2; color: Qt.rgba(0.176, 0.176, 0.173, 0.8) }
        }
        MouseArea {
            // Anywhere on the line takes the drag, not only the disc.
            x: view.splitX - 15; y: compareChrome.lineTop
            width: 30; height: compareChrome.lineBottom - compareChrome.lineTop
            cursorShape: Qt.SizeHorCursor
            preventStealing: true
            function track(mouse) {
                var p = mapToItem(view, mouse.x, mouse.y)
                if (view.picture.width > 1) view.editor.setComparePosition((p.x - view.picture.x) / view.picture.width)
            }
            onPressed: function(mouse) { track(mouse) }
            onPositionChanged: function(mouse) { if (pressed) track(mouse) }
        }
    }
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
        id: badges
        anchors.right: parent.right; anchors.top: parent.top
        anchors.margins: 8
        spacing: 4
        visible: preview.hasFrame
        Item {
            id: histogramSlot
            objectName: "histogramSlot"
            width: 200; height: 56
            anchors.right: parent.right
            // A soft black haze, not a plate: stacked rounded shapes whose
            // edge fades over 6 px stand in for the Mac's blurred rectangle.
            Repeater {
                model: 4
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -6 + index * 2
                    radius: 8 - index
                    color: Qt.rgba(0, 0, 0, 0.13)
                }
            }
            HistogramPlot {
                objectName: "canvasHistogram"
                anchors.fill: parent
                bins: view.editor.cropMode ? preview.uncroppedHistogram
                    : view.showOriginal ? preview.originalHistogram : preview.histogram
            }
        }
        Text {
            anchors.right: parent.right
            text: view.editor.cropMode ? L10n.tr("canvas.badge.uncropped") : L10n.tr("canvas.badge.full")
            color: Theme.text
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightTitle
            style: Text.Raised; styleColor: "#99000000"
        }
        // Session.canvasBadges: "original · decode" while the whole canvas
        // shows it (the split says Before / After instead), and "original…"
        // while either is waiting for it.
        Text {
            anchors.right: parent.right
            visible: view.showOriginal || (view.editor.originalWanted && preview.originalPending && !preview.originalReady)
            text: preview.originalPending && !preview.originalReady ? L10n.tr("canvas.badge.originalPending") : L10n.tr("canvas.badge.original")
            color: Theme.text
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightTitle
            style: Text.Raised; styleColor: "#99000000"
        }
    }
}
