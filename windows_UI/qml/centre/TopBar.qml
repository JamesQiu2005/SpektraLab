import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The canvas's own bar (TopBar.swift, v4): the left rail's toggle, the file
// (import, export), the tools (select, crop), Windows' undo / redo, the
// Process and Original capsules, the photo's line (file · size · colour space)
// ...... before/after, the zoom pill, zoom out / in, the right rail's toggle.
// Both sidebar toggles live here, so each is on screen whichever rail is
// folded.
//
// Not wired yet on Windows, and greyed with the reason: Process (the Mac's
// solve -- auto-exposure and the enlarger pack for this paper). Original
// shows the decode before the film (Space while held), before/after splits
// the canvas between the two, and zoom steps through the Mac's ladder
// (EditorState, FrameCanvas); all three wait while the crop editor is up.
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
        IconButton {
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
        // Accent while the Original is showing -- pinned here or held with
        // Space -- and muted otherwise (TopBar.swift `action`).
        PillButton {
            objectName: "originalButton"
            Layout.leftMargin: Theme.actionGap
            outlined: true
            text: L10n.tr("toolbar.original")
            active: bar.editor.showingOriginal
            available: preview.hasFrame && !preview.batchExporting
            toolTip: bar.editor.originalPinned ? L10n.tr("toolbar.originalShowingHelp") : L10n.tr("toolbar.originalHelp")
            reason: L10n.tr("toolbar.originalHelp")
            onClicked: bar.editor.toggleOriginal()
        }
        BusyIndicator {
            Layout.leftMargin: 10
            Layout.preferredWidth: 18; Layout.preferredHeight: 18
            running: preview.busy
            visible: running
        }
        // The photo's line: what is open, at what size, in what colour space,
        // and -- in the accent -- that the canvas is about to change.
        Text {
            id: photoLine
            Layout.leftMargin: 12
            Layout.fillWidth: true
            Layout.minimumWidth: 40
            text: preview.hasFrame
                ? preview.fileName + "  ·  " + preview.metadata.width + "×" + preview.metadata.height + "  ·  " + L10n.tr("toolbar.colourSpace")
                : preview.status
            elide: Text.ElideRight
            color: Theme.dim
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
            HoverHandler { id: lineHover }
            ToolTip.visible: lineHover.hovered && photoLine.truncated
            ToolTip.text: text
        }
        Text {
            Layout.leftMargin: 8
            visible: preview.hasFrame && preview.dirty
            text: L10n.tr("statusBar.updating")
            color: Theme.accent
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
        }
        // Before / after (BeforeAfterIcon.swift, traced from the drawing on
        // its 60.8 x 48.11 box into 25 x 16): the outlined frame, the divider,
        // the half-filled picture -- accent while the split is up. Y or
        // Alt+\ (the Mac's Y and Option-\) toggle it too.
        Item {
            id: compare
            objectName: "compareButton"
            Layout.leftMargin: 16
            Layout.preferredWidth: Theme.toolButton; Layout.preferredHeight: Theme.toolButton
            readonly property bool available: bar.editor.canCompare
            readonly property color ink: bar.editor.comparing ? Theme.accent : Theme.text
            opacity: available ? 1 : 0.4
            signal clicked()
            onClicked: bar.editor.toggleCompare()
            Rectangle { anchors.fill: parent; radius: 4; color: compareHover.hovered && compare.available ? Theme.hover : "transparent" }
            Item {
                x: 1.5; y: 6; width: 25; height: 16
                Rectangle { x: 2.72; y: 2.10; width: 7.82; height: 11.73; color: "transparent"; border.color: compare.ink; border.width: 1.4 }
                Rectangle { x: 14.32; y: 1.75; width: 8.29; height: 12.44; color: compare.ink; opacity: 0.5 }
                Rectangle { x: 11.83; y: 0; width: 1.4; height: 16; color: compare.ink }
            }
            HoverHandler { id: compareHover }
            TapHandler { enabled: compare.available; onTapped: compare.clicked() }
            ToolTip.visible: compareHover.hovered
            ToolTip.text: L10n.tr("toolbar.compareHelp")
            ToolTip.delay: 500
        }
        // The scale, sized to its number (TopBar.swift zoomPill): a click
        // opens the Mac's menu -- Fit, 25, 50, 100, 200, 400 % -- with the
        // current one marked. Ctrl+0 / Ctrl+1 and `,` / `.` are fit and 100 %.
        Item {
            id: zoomPill
            objectName: "zoomPill"
            Layout.leftMargin: 20
            Layout.preferredWidth: Math.max(Theme.zoomPillWidth, zoomText.implicitWidth + 14)
            Layout.preferredHeight: Theme.zoomPillHeight
            readonly property bool available: preview.hasFrame && !bar.editor.zoomLocked
            function at(percent) { return !bar.editor.fit && Math.abs(bar.editor.scalePercent - percent) < 1e-6 }
            opacity: available ? 1 : Theme.disabledOpacity
            Rectangle {
                anchors.fill: parent; radius: height / 2
                color: zoomMouse.containsMouse && zoomPill.available ? "#686866" : Theme.pill
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
                enabled: zoomPill.available
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: zoomMenu.popup(zoomPill, 0, zoomPill.height + 2)
            }
            ToolTip.visible: zoomMouse.containsMouse
            ToolTip.text: bar.editor.fit ? L10n.tr("toolbar.zoomFitted", [Math.round(bar.editor.scalePercent)])
                                         : L10n.tr("toolbar.zoomAt", [Math.round(bar.editor.scalePercent)])
            ToolTip.delay: 500
            RailMenu {
                id: zoomMenu
                RailMenuItem { text: L10n.tr("action.fit") + "  (Ctrl+0)"; marked: bar.editor.fit; onTriggered: bar.editor.resetView(true) }
                RailMenuItem { text: "25 %"; marked: zoomPill.at(25); onTriggered: bar.editor.zoomTo(0.25) }
                RailMenuItem { text: "50 %"; marked: zoomPill.at(50); onTriggered: bar.editor.zoomTo(0.5) }
                RailMenuItem { text: "100 %  (Ctrl+1)"; marked: zoomPill.at(100); onTriggered: bar.editor.zoomTo(1) }
                RailMenuItem { text: "200 %"; marked: zoomPill.at(200); onTriggered: bar.editor.zoomTo(2) }
                RailMenuItem { text: "400 %"; marked: zoomPill.at(400); onTriggered: bar.editor.zoomTo(4) }
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
