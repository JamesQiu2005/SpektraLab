import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import SpektraLab.Native 1.0

// Half-Frame Pair (PairSection.swift), under the Navigator while a pair is on
// the canvas. The pair is worked on the canvas -- a click picks a frame, the +
// on an empty hole adds one, a right click replaces, turns or crops it -- and
// this section is what the canvas cannot say: which way the camera was held,
// how far apart the frames are, and the picked frame's numbers (its crop under
// the hole, where its exposure lands). Built from the rail's own parts.
//
// The layer list is the Mac's: Film, then the two frames with their pictures.
// Picking a frame makes Input / Camera, Scene Placement, the Enlarger and
// Post-Dev act on it alone (PreviewControllerPairs.cpp).
MacSection {
    id: section
    required property EditorState editor
    sectionId: "pair"
    title: L10n.tr("pair.title")
    visible: pair.active === true

    readonly property var pair: preview.pair
    readonly property var holes: pair.holes || []
    readonly property string picked: pair.layer || "film"
    readonly property int sideIndex: picked === "first" ? 0 : picked === "second" ? 1 : -1
    readonly property var hole: sideIndex >= 0 ? holes[sideIndex] : null
    readonly property bool usable: preview.settingsEditable
    signal pickFrame(string side)
    onPickFrame: function(side) { picker.openFor(side) }
    PairFramePicker { id: picker }

    function holeTitle(index) {
        if (pair.turned) return L10n.tr(index === 0 ? "pair.topFrame" : "pair.bottomFrame")
        return L10n.tr(index === 0 ? "pair.leftFrame" : "pair.rightFrame")
    }
    function holeSubtitle(h) {
        if (!h || !h.filled) return L10n.tr("pair.empty")
        return h.exists ? h.name : L10n.tr("pair.missing", [h.name])
    }
    // The drag's placement while one is in flight, the written one otherwise.
    function shownPlacement(h) {
        var d = pair.drag
        if (d && d.active && h && d.side === h.side && d.placement) return d.placement
        return h && h.placement ? h.placement : { scale: 1, x: 0, y: 0, quarterTurns: 0 }
    }
    function preview3(scale, x, y) {
        if (!section.hole) return
        preview.previewPairPlacement(section.hole.side, scale, x, y)
    }

    // --- the layer list ---------------------------------------------------------
    Repeater {
        model: 3
        Rectangle {
            id: row
            required property int index
            readonly property string key: index === 0 ? "film" : index === 1 ? "first" : "second"
            readonly property var h: index === 0 ? null : section.holes[index - 1]
            readonly property bool on: section.picked === key
            Layout.fillWidth: true
            Layout.preferredHeight: 32
            radius: 6
            color: on ? Qt.rgba(0.976, 0.969, 0.953, 0.1) : rowMouse.containsMouse ? Qt.rgba(0.976, 0.969, 0.953, 0.05) : "transparent"
            objectName: "pairLayer_" + key
            Rectangle {
                id: chip
                x: 6; anchors.verticalCenter: parent.verticalCenter
                width: section.pair.turned ? 24 : 18; height: section.pair.turned ? 18 : 24
                radius: 2
                color: Theme.well
                clip: true
                Text {
                    anchors.centerIn: parent
                    visible: chip.thumb === undefined
                    text: row.index === 0 || (row.h && row.h.filled) ? Icons.photo : Icons.add
                    font.family: Theme.iconFamily; font.pixelSize: 9
                    color: Theme.dim
                }
                // The frame's own filmstrip picture, when the strip has one.
                readonly property var thumb: {
                    if (!row.h || !row.h.filled) return undefined
                    var c = section.pair.candidates || []
                    for (var i = 0; i < c.length; ++i) if (c[i].used && c[i].name === row.h.name) return c[i].thumbnail
                    return undefined
                }
                Loader {
                    anchors.fill: parent
                    active: chip.thumb !== undefined
                    sourceComponent: FrameCanvas { image: chip.thumb; enabled: false }
                }
            }
            Column {
                anchors.left: chip.right; anchors.leftMargin: 8
                anchors.right: parent.right; anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1
                Text {
                    text: row.index === 0 ? L10n.tr("pair.film") : section.holeTitle(row.index - 1)
                    color: Theme.text
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel; font.weight: Theme.weightText
                }
                Text {
                    width: parent.width
                    text: row.index === 0 ? L10n.tr("pair.filmSubtitle", [Number(section.pair.spacing || 1).toFixed(1)])
                                          : section.holeSubtitle(row.h)
                    elide: Text.ElideMiddle
                    color: row.h && row.h.filled && !row.h.exists ? Theme.warning : Theme.dim
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
                }
            }
            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: preview.setPairLayer(row.key)
            }
        }
    }

    // --- the Film layer -----------------------------------------------------------
    ParamRow {
        visible: section.picked === "film"
        label: L10n.tr("pair.camera")
        available: section.usable
        PillSwitch {
            objectName: "pairCamera"
            anchors.verticalCenter: parent.verticalCenter
            model: [L10n.tr("pair.level"), L10n.tr("pair.turned")]
            currentIndex: section.pair.turned ? 1 : 0
            onActivated: function(index) { preview.setPairTurned(index === 1) }
        }
    }
    ScrubSlider {
        visible: section.picked === "film"
        label: L10n.tr("pair.spacing")
        sublabel: "mm"
        from: 0.5; to: 2.0; defaultValue: 1.0
        step: 0.05; snap: 0.1; decimals: 1
        value: Number(section.pair.spacing || 1)
        gestureKey: "pairSpacing"
        available: section.usable && section.pair.onStrip !== true
        reason: L10n.tr("pair.spacingOnStrip")
        onMoved: function(v) { preview.setPairSpacing(v) }
    }
    RowLayout {
        visible: section.picked === "film"
        PillButton {
            text: L10n.tr("pair.swap")
            available: section.usable && (section.pair.filled || 0) > 0
            onClicked: preview.swapPairFrames()
        }
        Item { Layout.fillWidth: true }
    }
    Note {
        visible: section.picked === "film"
        text: L10n.tr("pair.filmNote")
    }

    // --- a frame in its hole -------------------------------------------------------
    Text {
        visible: !!(section.hole && section.hole.filled)
        Layout.fillWidth: true
        text: L10n.tr("pair.cropUnderHole")
        color: Theme.dim
        font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
    }
    RowLayout {
        visible: !!(section.hole && section.hole.filled)
        spacing: 8
        PillButton {
            objectName: "pairCropButton"
            text: section.pair.placing ? L10n.tr("pair.done") : L10n.tr("pair.cropOnCanvas")
            active: section.pair.placing === true
            available: section.usable && !!(section.hole && section.hole.exists)
            onClicked: preview.setPairPlacing(!section.pair.placing)
        }
        PillButton {
            text: L10n.tr("pair.turn")
            available: section.usable
            onClicked: preview.turnPairPicture(section.hole.side)
        }
        Item { Layout.fillWidth: true }
    }
    ScrubSlider {
        visible: !!(section.hole && section.hole.filled)
        label: L10n.tr("pair.scale"); sublabel: "×"
        from: 1; to: 4; defaultValue: 1; step: 0.01; snap: 0.05; decimals: 2
        value: Number(section.shownPlacement(section.hole).scale)
        available: section.usable && preview.pair.shown === true
        onMoved: function(v) { var p = section.shownPlacement(section.hole); section.preview3(v, p.x, p.y) }
    }
    ScrubSlider {
        visible: !!(section.hole && section.hole.filled)
        label: L10n.tr("pair.across")
        from: -1; to: 1; defaultValue: 0; step: 0.01; snap: 0.05; decimals: 2; signed: true
        value: Number(section.shownPlacement(section.hole).x)
        available: section.usable && preview.pair.shown === true
        onMoved: function(v) { var p = section.shownPlacement(section.hole); section.preview3(p.scale, v, p.y) }
    }
    ScrubSlider {
        visible: !!(section.hole && section.hole.filled)
        label: L10n.tr("pair.upDown")
        from: -1; to: 1; defaultValue: 0; step: 0.01; snap: 0.05; decimals: 2; signed: true
        value: Number(section.shownPlacement(section.hole).y)
        available: section.usable && preview.pair.shown === true
        onMoved: function(v) { var p = section.shownPlacement(section.hole); section.preview3(p.scale, p.x, v) }
    }
    // Where this frame's exposure lands (CameraSection.swift's "Applies to"):
    // on the frame, or on the frame and the film around it.
    ParamRow {
        visible: !!(section.hole && section.hole.filled)
        label: L10n.tr("pair.exposureAppliesTo")
        available: section.usable
        toolTip: L10n.tr("pair.scopeHelp")
        PillSwitch {
            anchors.verticalCenter: parent.verticalCenter
            model: [L10n.tr("pair.scopeFrame"), L10n.tr("pair.scopeFilm")]
            currentIndex: section.hole && section.hole.exposureScope === "film" ? 1 : 0
            onActivated: function(index) { preview.setPairScope("exposure", index === 1 ? "film" : "frame") }
        }
    }
    RowLayout {
        visible: !!section.hole
        spacing: 8
        PillButton {
            objectName: "pairPickButton"
            text: section.hole && section.hole.filled ? L10n.tr("pair.replace") : L10n.tr("pair.addFrame")
            available: section.usable
            onClicked: section.pickFrame(section.hole.side)
        }
        PillButton {
            visible: !!(section.hole && section.hole.filled)
            text: L10n.tr("pair.remove")
            available: section.usable
            onClicked: preview.removePairFrame(section.hole.side)
        }
        Item { Layout.fillWidth: true }
    }
    Note {
        visible: !!section.hole
        text: section.hole && section.hole.filled ? L10n.tr("pair.frameNote") : L10n.tr("pair.emptyNote")
    }
}
