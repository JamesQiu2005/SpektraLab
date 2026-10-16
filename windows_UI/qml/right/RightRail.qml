import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The Parameters rail (RightPanel.swift, v4): its name and the Pre-Dev /
// Post-Dev switch on the header row, then the Pre-Dev sections in the Mac's
// order -- Latitude, Input / Camera, Film Format, Scene Placement, Tone Mask
// -- and after them the two Windows-only sections, RAW Decode and Photo Info.
// The status line, batch progress and warnings sit in a compact footer that
// does not scroll away, because they report on operations rather than set a
// parameter.
//
// Every row here shares one label column (Theme.parameterLabelWidth, the
// Mac's `SliderMetrics.parameters`), so the tracks start on one line.
// Post-Dev -- the grade on the finished scan -- is not built on Windows yet;
// its side of the switch is greyed with the reason.
Rectangle {
    id: rail
    required property EditorState editor
    property real railLabelWidth: Theme.parameterLabelWidth
    Layout.preferredWidth: editor.rightWidth
    Layout.fillHeight: true
    visible: !editor.rightCollapsed
    color: Theme.card

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.headerBarHeight
            Text {
                id: railTitle
                x: Theme.rowInset; anchors.verticalCenter: parent.verticalCenter
                text: L10n.tr("rail.parameters")
                color: Theme.text
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontRail; font.weight: Theme.weightTitle
            }
            PillSwitch {
                anchors.left: railTitle.right; anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                model: [L10n.tr("rail.preDev"), L10n.tr("rail.postDev")]
                currentIndex: rail.editor.parametersTab
                optionEnabled: [true, false]
                optionToolTips: ["", L10n.tr("placeholder.postDev")]
                onActivated: function(index) { rail.editor.parametersTab = index }
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
                LatitudeSection {}
                CameraSection {}
                FilmFormatSection {}
                ScenePlacementSection {}
                ToneMaskSection {}
                DecodeSection {}
                InfoSection { divider: false }
            }
        }
        StatusSection { editor: rail.editor }
    }
    Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Theme.ruleRegion }
    RailResizeHandle {
        anchors.left: parent.left; anchors.leftMargin: -width / 2
        height: parent.height
        z: 2
        railWidth: rail.editor.rightWidth
        growsRight: false
        onResized: function(w) { rail.editor.setRightWidth(w) }
        onResetRequested: rail.editor.setRightWidth(Theme.rightRailStandard)
    }
}
