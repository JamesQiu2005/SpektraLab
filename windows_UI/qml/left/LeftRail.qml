import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The left rail, "Film and Print" (LeftPanel.swift, v4): the choices of
// material -- the navigator, the settings clipboard, the film, the film's
// edge and date back, the paper, the crop and the enlarger, top to bottom in
// the Mac's order. Everything that is a parameter of those choices is on the
// Parameters rail.
//
// Its width is the user's (the grip on its right edge, EditorState) and it
// folds with the sidebar button on the tool bar. Film Edge and Date Back fold
// by default, as the Mac's do, and open when their switch is turned on.
Rectangle {
    id: rail
    required property EditorState editor
    // The label column every ParamRow in this rail takes (ParamRow.qml).
    property real railLabelWidth: Theme.labelWidth
    Layout.preferredWidth: editor.leftWidth
    Layout.fillHeight: true
    visible: !editor.leftCollapsed
    color: Theme.card

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.headerBarHeight
            Text {
                x: Theme.rowInset; anchors.verticalCenter: parent.verticalCenter
                text: L10n.tr("rail.filmAndPrint")
                color: Theme.text
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontRail; font.weight: Theme.weightTitle
            }
        }
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.rule }
        ScrollView {
            id: scroll
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            contentWidth: availableWidth
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ScrollBar.vertical: RailScrollBar { parent: scroll; x: scroll.width - width; height: scroll.availableHeight }
            ColumnLayout {
                width: scroll.availableWidth
                spacing: 0
                NavigatorSection { editor: rail.editor }
                ClipboardSection { editor: rail.editor }
                FilmSection {}
                FilmEdgeSection { editor: rail.editor }
                DateBackSection {}
                PrintSection {}
                CropSection { editor: rail.editor }
                EnlargerSection { divider: false }
            }
        }
    }
    // The wall between this rail and the centre column runs the window's full
    // height (v3); an overlay, so it does not move the canvas by a pixel.
    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.ruleRegion }
    RailResizeHandle {
        anchors.right: parent.right; anchors.rightMargin: -width / 2
        height: parent.height
        z: 2
        railWidth: rail.editor.leftWidth
        growsRight: true
        onResized: function(w) { rail.editor.setLeftWidth(w) }
        onResetRequested: rail.editor.setLeftWidth(Theme.leftRailStandard)
    }
}
