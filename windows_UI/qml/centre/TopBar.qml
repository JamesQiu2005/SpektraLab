import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import SpektraLab.Native 1.0

// The canvas's own bar (TopBar.swift, v4): the application menu (Windows
// only: the Mac's menu bar, shell/AppMenu.qml), the left rail's toggle, the file
// (import, export), the tools (select, crop), Windows' undo / redo, the
// Process and Original capsules, the photo's line (file · size · colour space
// → display, with a warning badge when colour management falls back)
// ...... before/after, the zoom pill, zoom out / in, the right rail's toggle.
// Both sidebar toggles live here, so each is on screen whichever rail is
// folded.
//
// Not wired yet on Windows, and greyed with the reason: Process (the Mac's
// solve -- auto-exposure and the enlarger pack for this paper), Original and
// before/after (no unprocessed view yet). The canvas has two scales, so zoom
// in and out step between fit and 100 %; the pill shows the scale, a click
// toggles the two, and its menu lists the Mac's steps.
//
// "undoButton" and "redoButton" are found by name by the --self-test
// (main.cpp), which reads their `enabled` and invokes `clicked`.
Rectangle {
    id: bar
    required property EditorState editor
    Layout.fillWidth: true
    implicitHeight: Theme.headerBarHeight
    color: Theme.card

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.barPadding; anchors.rightMargin: Theme.barPadding
        spacing: 0
        // The application menu (shell/AppMenu.qml): where the Mac's menu bar
        // commands are on Windows.
        AppMenu { editor: bar.editor }
        IconButton {
            Layout.leftMargin: Theme.barIconGap
            glyph: Icons.sidebarLeft; glyphSize: 15
            toolTip: bar.editor.leftCollapsed ? L10n.tr("toolbar.showLeftRail") : L10n.tr("toolbar.hideLeftRail")
            onClicked: bar.editor.leftCollapsed = !bar.editor.leftCollapsed
        }
        IconButton {
            Layout.leftMargin: Theme.barClusterGap
            glyph: Icons.importFile
            available: bar.editor.canBrowse
            toolTip: L10n.tr("toolbar.importHelp")
            reason: L10n.tr("toolbar.importHelp")
            onClicked: bar.editor.importRequested()
        }
        IconButton {
            Layout.leftMargin: Theme.barIconGap
            glyph: Icons.exportFile
            available: bar.editor.canExport
            toolTip: L10n.tr("toolbar.exportHelp")
            reason: L10n.tr("toolbar.exportHelp")
            onClicked: bar.editor.openExport()
        }
        IconButton {
            Layout.leftMargin: Theme.barClusterGap
            glyph: Icons.pointer
            active: !bar.editor.cropMode
            dimmed: bar.editor.cropMode
            toolTip: L10n.tr("toolbar.selectHelp")
            onClicked: if (bar.editor.cropMode) bar.editor.cancelCrop()
        }
        IconButton {
            Layout.leftMargin: Theme.barIconGap
            glyph: Icons.crop
            active: bar.editor.cropMode
            dimmed: !bar.editor.cropMode
            available: bar.editor.canEditCrop
            toolTip: bar.editor.cropMode ? L10n.tr("toolbar.cropFinishHelp") : L10n.tr("toolbar.cropHelp")
            reason: L10n.tr("toolbar.cropHelp")
            onClicked: bar.editor.toggleCrop()
        }
        IconButton {
            Layout.leftMargin: Theme.barClusterGap
            buttonObjectName: "undoButton"
            glyph: Icons.undo; glyphSize: 15
            available: preview.settingsEditable && preview.canUndo && !bar.editor.cropMode
            toolTip: L10n.tr("toolbar.undoHelp")
            onClicked: preview.undo()
        }
        IconButton {
            Layout.leftMargin: Theme.barIconGap
            buttonObjectName: "redoButton"
            glyph: Icons.redo; glyphSize: 15
            available: preview.settingsEditable && preview.canRedo && !bar.editor.cropMode
            toolTip: L10n.tr("toolbar.redoHelp")
            onClicked: preview.redo()
        }
        PillButton {
            Layout.leftMargin: Theme.barActionLeading
            outlined: true
            text: L10n.tr("toolbar.process")
            available: false
            reason: L10n.tr("placeholder.process")
        }
        PillButton {
            Layout.leftMargin: Theme.actionGap
            outlined: true
            text: L10n.tr("toolbar.original")
            available: false
            reason: L10n.tr("placeholder.original")
        }
        BusyIndicator {
            Layout.leftMargin: 10
            Layout.preferredWidth: 18; Layout.preferredHeight: 18
            running: preview.busy
            visible: running
        }
        // The photo's line: what is open and at what size, and -- in the
        // accent -- that the canvas is about to change.
        Text {
            id: photoLine
            Layout.leftMargin: 12
            Layout.fillWidth: true
            Layout.minimumWidth: 40
            text: preview.hasFrame ? preview.fileName + "  ·  " + preview.metadata.width + "×" + preview.metadata.height : preview.status
            elide: Text.ElideRight
            color: Theme.dim
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
            HoverHandler { id: lineHover }
            ToolTip.visible: lineHover.hovered && photoLine.truncated
            ToolTip.text: text
        }
        // Its colour: the frame's space and the display it is managed to
        // (DisplayColour, the window's ColorPipeline), e.g. "sRGB → HP Z31x"
        // or "sRGB → sRGB (assumed)". Its own item, so a long file name
        // elides before it; the monitor's name only (the profile file is in
        // the tooltip and Settings > Display), and a badge when colour
        // management falls back.
        Text {
            id: colourLine
            objectName: "colourLine"
            Layout.leftMargin: 8
            Layout.maximumWidth: 190
            visible: preview.hasFrame
            readonly property string frameSpace: preview.metadata.colorSpace ? preview.metadata.colorSpace : L10n.tr("toolbar.colourSpace")
            // "HP Z31x - HP Z31x AdobeRGB Profile.icm" -> "HP Z31x".
            readonly property string monitor: {
                var name = DisplayColour.displayName
                var cut = name.indexOf(" - ")
                return cut > 0 ? name.substring(0, cut) : name
            }
            text: frameSpace + (monitor.length > 0 ? " " + L10n.tr("toolbar.displayTarget", [monitor]) : "")
            elide: Text.ElideRight
            color: Theme.dim
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
            HoverHandler { id: colourHover }
            ToolTip.visible: colourHover.hovered
            ToolTip.text: L10n.tr("toolbar.displayHelp", [DisplayColour.displayName]) + (DisplayColour.status.length > 0 ? "\n" + DisplayColour.status : "")
            ToolTip.delay: 500
            TapHandler { onTapped: bar.editor.settingsRequested("display") }
        }
        Text {
            id: colourWarning
            objectName: "colourWarning"
            Layout.leftMargin: 4
            visible: DisplayColour.status.length > 0
            text: Icons.warning
            color: Theme.warning
            font.family: Theme.iconFamily; font.pixelSize: 12
            HoverHandler { id: warningHover }
            ToolTip.visible: warningHover.hovered
            ToolTip.text: L10n.tr("toolbar.displayWarning", [DisplayColour.status])
            ToolTip.delay: 300
            TapHandler { onTapped: bar.editor.settingsRequested("display") }
        }
        Text {
            Layout.leftMargin: 8
            visible: preview.hasFrame && preview.dirty
            text: L10n.tr("statusBar.updating")
            color: Theme.accent
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
        }
        // Before / after: the Mac draws its own glyph, two frames side by
        // side with the processed half filled.
        Item {
            id: compare
            Layout.leftMargin: 16
            Layout.preferredWidth: Theme.toolButton; Layout.preferredHeight: Theme.toolButton
            opacity: 0.4
            Rectangle { x: 3; y: 8; width: 10; height: 12; color: "transparent"; border.color: Theme.text; border.width: 1.2; radius: 1 }
            Rectangle { x: 14; y: 8; width: 10; height: 12; color: Theme.text; radius: 1 }
            HoverHandler { id: compareHover }
            ToolTip.visible: compareHover.hovered
            ToolTip.text: L10n.tr("placeholder.compare")
            ToolTip.delay: 500
        }
        // The scale. A click toggles fit and 100 % (Ctrl+0 / Ctrl+1); the
        // menu (right-click) lists the Mac's steps, the ones the canvas
        // cannot take yet greyed.
        Item {
            id: zoomPill
            Layout.leftMargin: 20
            Layout.preferredWidth: Math.max(Theme.zoomPillWidth, zoomText.implicitWidth + 14)
            Layout.preferredHeight: Theme.zoomPillHeight
            opacity: preview.hasFrame ? 1 : Theme.disabledOpacity
            Rectangle {
                anchors.fill: parent; radius: height / 2
                color: zoomMouse.containsMouse && preview.hasFrame ? "#686866" : Theme.pill
            }
            Text {
                id: zoomText
                anchors.centerIn: parent
                text: preview.hasFrame ? Math.round(bar.editor.scalePercent) + " %" : "—"
                color: Theme.text
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel; font.weight: Theme.weightText
                    }
            MouseArea {
                id: zoomMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: preview.hasFrame
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: function(mouse) {
                    if (mouse.button === Qt.RightButton) zoomMenu.popup(zoomPill, 0, zoomPill.height + 2)
                    else bar.editor.resetView(!bar.editor.fit || bar.editor.cropMode)
                }
            }
            ToolTip.visible: zoomMouse.containsMouse
            ToolTip.text: bar.editor.fit ? L10n.tr("toolbar.zoomFitted", [Math.round(bar.editor.scalePercent)]) : L10n.tr("toolbar.zoomActual")
            ToolTip.delay: 500
            RailMenu {
                id: zoomMenu
                RailMenuItem { text: L10n.tr("action.fit") + "  (Ctrl+0)"; marked: bar.editor.fit; onTriggered: bar.editor.resetView(true) }
                RailMenuItem { text: "100 %  (Ctrl+1)"; marked: !bar.editor.fit; enabled: !bar.editor.cropMode; onTriggered: bar.editor.resetView(false) }
                MenuSeparator {}
                RailMenuItem { text: "25 %"; enabled: false }
                RailMenuItem { text: "50 %"; enabled: false }
                RailMenuItem { text: "200 %"; enabled: false }
                RailMenuItem { text: "400 %"; enabled: false }
            }
        }
        IconButton {
            Layout.leftMargin: Theme.zoomGap
            glyph: Icons.zoomOut
            available: bar.editor.canZoomOut
            toolTip: L10n.tr("toolbar.zoomOut")
            onClicked: bar.editor.zoomOut()
        }
        IconButton {
            glyph: Icons.zoomIn
            available: bar.editor.canZoomIn
            toolTip: L10n.tr("toolbar.zoomIn")
            onClicked: bar.editor.zoomIn()
        }
        IconButton {
            Layout.leftMargin: Theme.barClusterGap
            glyph: Icons.sidebarRight; glyphSize: 15
            toolTip: bar.editor.rightCollapsed ? L10n.tr("toolbar.showRightRail") : L10n.tr("toolbar.hideRightRail")
            onClicked: bar.editor.rightCollapsed = !bar.editor.rightCollapsed
        }
    }
}
