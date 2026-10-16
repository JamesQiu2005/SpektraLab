import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Film Edge (FilmEdgeSection.swift, RFC-032): the rebate, the holes and the
// edge print around the picture. The rows are the order of the decisions --
// format, view and framing, then the gate and the scan, then the light -- and
// every control develops on release, as everywhere on this rail.
//
// The framing is the crop, held at the gate's shape: the Framing row opens the
// crop editor over the undeveloped picture and turns the gate between upright
// and across without turning the picture; Straighten is the held crop's. The
// controller holds the crop (setFilmEdgeActive, flipFilmEdgeGate) and the
// host cuts the picture with it, so the canvas shows the film and the export
// writes the strip.
//
// Not drawn, as on the Mac: the drawing's Turn row (no `overscan_turn` in the
// engine) and a Scale slider (dragging the crop in the gate is the scale).
// The half-frame pair's entry is the Mac's row under a Half format; on a pair
// the format is fixed. The Carrier row is the engine's `overscan_carrier`, which the Mac
// leaves at None; it is offered here for a strip scan only.
MacSection {
    id: section
    required property EditorState editor
    sectionId: "filmEdge"
    title: L10n.tr("filmEdge.title")
    // Folded, as the Mac's starts, unless the photograph has a film edge on
    // (switching it on opens it): until the user folds or opens it.
    defaultExpanded: on

    readonly property var p: preview.parameters
    readonly property var edge: preview.filmEdge
    readonly property bool on: p.overscan_active === true
    readonly property bool usable: on && preview.settingsEditable
    readonly property string offReason: L10n.tr("filmEdge.switchOn")
    readonly property var formats: preview.filmFormats
    readonly property int formatIndex: {
        for (var i = 0; i < formats.length; ++i) if (formats[i].id === p.overscan_format) return i
        return 0
    }
    readonly property var format: formats.length > 0 ? formats[formatIndex] : null
    function formatTitle(f) { return f.id === "135_half" ? L10n.tr("filmEdge.format.half") : f.title }
    function viewTitle(v) { return L10n.tr(v === "filed" ? "filmEdge.view.filed" : "filmEdge.view.strip") }
    function grouped(n) { return Number(n).toLocaleString(Qt.locale("en_US"), "f", 0) }
    function set(key, value) { preview.setParameter(key, value) }

    headerCheckVisible: true
    headerChecked: on
    headerCheckAvailable: preview.settingsEditable
    headerCheckToolTip: L10n.tr("filmEdge.toggleHelp")
    // Switching on opens the section, since everything it asks for is under
    // the header; switching off leaves it as it was.
    onHeaderToggled: function(checked) {
        if (preview.setFilmEdgeActive(checked) && checked) section.setExpanded(true)
    }
    caption: on ? "" : L10n.tr("filmEdge.off")
    foldedCaption: on && format ? formatTitle(format) + " · " + viewTitle(p.overscan_mode) : ""

    // Format: a pill of the formats and the gate's size at the row's end.
    ParamRow {
        label: L10n.tr("filmEdge.format")
        available: section.usable && preview.pair.active !== true
        reason: preview.pair.active === true ? L10n.tr("filmEdge.pairFormat") : section.offReason
        Item {
            width: parent.width - gateLabel.width - 6
            height: parent.height
            PillDropdown {
                objectName: "filmEdgeFormat"
                model: { var m = []; for (var i = 0; i < section.formats.length; ++i) m.push(section.formatTitle(section.formats[i])); return m }
                currentIndex: { model; return section.formatIndex }
                onActivated: function(index) { section.set("overscan_format", section.formats[index].id) }
            }
        }
        Text {
            id: gateLabel
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            text: section.format ? section.format.gate : ""
            color: Theme.dim
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
        }
    }
    // A half frame offers the way into a pair right under its format
    // (FilmEdgeSection.swift:36-46, 99-115): the photograph becomes the first
    // frame of a new pair, and the canvas shows the second hole with a + on it.
    RowLayout {
        visible: section.p.overscan_format === "135_half" && preview.pair.active !== true
        PillButton {
            objectName: "enterPair"
            text: L10n.tr("filmEdge.enterPair")
            available: preview.canEnterPair
            toolTip: L10n.tr("filmEdge.enterPairHelp")
            reason: L10n.tr("filmEdge.enterPairHelp")
            onClicked: preview.enterPair()
        }
        Item { Layout.fillWidth: true }
    }
    // A pair is always 135 half, exposed twice: its format is not a choice.
    Note {
        visible: preview.pair.active === true
        text: L10n.tr("filmEdge.pairFormat")
    }
    ParamRow {
        label: L10n.tr("filmEdge.view")
        available: section.usable
        reason: section.offReason
        PillSwitch {
            anchors.verticalCenter: parent.verticalCenter
            model: [L10n.tr("filmEdge.view.strip"), L10n.tr("filmEdge.view.filed")]
            currentIndex: section.p.overscan_mode === "filed" ? 1 : 0
            onActivated: function(index) { section.set("overscan_mode", index === 1 ? "filed" : "strip") }
        }
    }
    // Framing in the gate: the crop tool, re-aimed. The glyph turns the gate
    // between upright and across without turning the picture.
    ParamRow {
        label: L10n.tr("filmEdge.framing")
        available: section.usable && section.editor.canEditCrop
        reason: section.on ? "" : section.offReason
        Rectangle {
            id: framingPill
            width: parent.width - gateButton.width - 6
            height: Theme.controlHeight
            anchors.verticalCenter: parent.verticalCenter
            radius: height / 2
            color: framingMouse.containsMouse ? "#686866" : Theme.pill
            Row {
                anchors.left: parent.left; anchors.leftMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                spacing: 5
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Icons.crop
                    font.family: Theme.iconFamily; font.pixelSize: 10
                    color: section.editor.cropMode ? Theme.accent : Theme.secondaryText
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: section.editor.cropMode ? L10n.tr("filmEdge.framing.active") : L10n.tr("filmEdge.framing.inGate")
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel; font.weight: Theme.weightText
                    color: section.editor.cropMode ? Theme.accent : Theme.secondaryText
                }
            }
            MouseArea {
                id: framingMouse
                objectName: "filmEdgeFraming"
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: section.editor.toggleCrop()
            }
            ToolTip.visible: framingMouse.containsMouse
            ToolTip.text: L10n.tr("filmEdge.framing.help")
            ToolTip.delay: 600
        }
        IconButton {
            id: gateButton
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            size: 22
            buttonObjectName: "filmEdgeGateFlip"
            readonly property bool upright: section.edge.upright === true
            Rectangle {
                anchors.centerIn: parent
                width: gateButton.upright ? 8 : 12; height: gateButton.upright ? 12 : 8
                radius: 1
                color: "transparent"
                border.width: 1; border.color: Theme.text
            }
            toolTip: upright ? L10n.tr("filmEdge.gateUpright") : L10n.tr("filmEdge.gateAcross")
            onClicked: preview.flipFilmEdgeGate()
        }
    }
    // The held crop's straighten; the refit happens once, on release.
    ScrubSlider {
        label: L10n.tr("crop.straighten")
        sublabel: L10n.tr("crop.straightenUnit")
        from: -45; to: 45; defaultValue: 0
        step: 0.1; snap: 1; decimals: 1; signed: true; suffix: "°"
        value: preview.straightenDegrees
        live: false
        gestureKey: "straightenDegrees"
        available: section.usable && section.editor.canEditCrop && !section.editor.cropMode && preview.pair.active !== true
        reason: preview.pair.active === true ? L10n.tr("pair.noCrop") : section.on ? L10n.tr("crop.waitForEditor") : section.offReason
        onMoved: function(v) { preview.setStraightenDegrees(Math.round(v * 10) / 10) }
    }
    // The picture's own pixels, and the film built around them. The border
    // is outside the picture and takes none of its pixels (RFC-032 §10).
    Note {
        text: {
            var e = section.edge
            if (!preview.hasFrame || !e.pictureWidth) return "—"
            var picture = section.grouped(e.pictureWidth) + " × " + section.grouped(e.pictureHeight)
            if (!e.filmWidth) return picture
            var film = section.grouped(e.filmWidth) + " × " + section.grouped(e.filmHeight)
            var mp = (e.filmWidth * e.filmHeight / 1e6).toFixed(1)
            return L10n.tr(e.filmMeasured ? "filmEdge.sizeMeasured" : "filmEdge.size", [picture, film, mp])
        }
        opacity: section.on ? 1 : Theme.disabledOpacity
    }

    Text {
        Layout.fillWidth: true
        Layout.topMargin: 6
        text: L10n.tr("filmEdge.gateAndScan")
        color: Theme.dim
        font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
        opacity: section.on ? 1 : Theme.disabledOpacity
    }
    ParamRow {
        label: L10n.tr("filmEdge.gate")
        available: section.usable
        reason: section.offReason
        PillDropdown {
            readonly property var keys: ["auto", "square", "rounded", "eared", "shouldered", "kicked"]
            model: [L10n.tr("filmEdge.gate.auto"), L10n.tr("filmEdge.gate.square"), L10n.tr("filmEdge.gate.rounded"),
                    L10n.tr("filmEdge.gate.eared"), L10n.tr("filmEdge.gate.shouldered"), L10n.tr("filmEdge.gate.kicked")]
            currentIndex: { model; return Math.max(0, keys.indexOf(section.p.overscan_gate)) }
            onActivated: function(index) { section.set("overscan_gate", keys[index]) }
        }
    }
    ParamRow {
        label: L10n.tr("filmEdge.holes")
        available: section.usable
        reason: section.offReason
        PillSwitch {
            anchors.verticalCenter: parent.verticalCenter
            model: [L10n.tr("filmEdge.holes.white"), L10n.tr("filmEdge.holes.black")]
            currentIndex: section.p.overscan_holes === "black" ? 1 : 0
            onActivated: function(index) { section.set("overscan_holes", index === 1 ? "black" : "white") }
        }
    }
    ParamRow {
        label: L10n.tr("filmEdge.carrier")
        available: section.usable && section.p.overscan_mode !== "filed"
        reason: section.on ? L10n.tr("filmEdge.carrier.reason") : section.offReason
        toolTip: L10n.tr("filmEdge.carrier.help")
        PillSwitch {
            anchors.verticalCenter: parent.verticalCenter
            sideWidth: 48
            readonly property var keys: ["none", "black", "open"]
            model: [L10n.tr("filmEdge.carrier.none"), L10n.tr("filmEdge.carrier.black"), L10n.tr("filmEdge.carrier.open")]
            currentIndex: Math.max(0, keys.indexOf(section.p.overscan_carrier))
            onActivated: function(index) { section.set("overscan_carrier", keys[index]) }
        }
    }
    // The body: which camera shot the roll. Its number is the seed, so the
    // same number is the same gate, the same margins and the same holes.
    ParamRow {
        label: L10n.tr("filmEdge.body")
        available: section.usable
        reason: section.offReason
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: L10n.tr("filmEdge.bodyNumber", [Math.round(Number(section.p.overscan_camera_seed))])
            color: Theme.text
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
        }
        PillButton {
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            text: L10n.tr("filmEdge.another")
            toolTip: L10n.tr("filmEdge.anotherHelp")
            onClicked: preview.anotherCameraBody()
        }
    }
    // The advance and the scan: where this frame landed on the roll, and how
    // the scanner held it. Per photo; it has no number worth showing.
    ParamRow {
        label: L10n.tr("filmEdge.advance")
        available: section.usable
        reason: section.offReason
        PillButton {
            width: parent.width
            anchors.verticalCenter: parent.verticalCenter
            text: L10n.tr("filmEdge.anotherFrame")
            toolTip: L10n.tr("filmEdge.anotherFrameHelp")
            onClicked: preview.anotherFrameAdvance()
        }
    }
    // The frame's number on the edge print; 0 reads "Auto", the seed's draw.
    ScrubSlider {
        label: L10n.tr("filmEdge.frameNumber")
        from: 0; to: 99; defaultValue: 0
        step: 1; snap: 1; decimals: 0
        format: function(v) { return v < 0.5 ? L10n.tr("filmEdge.frameNumberAuto") : String(Math.round(v)) }
        parse: function(t) { return t.trim().length === 0 ? 0 : (/^\s*\d+\s*$/.test(t) ? parseInt(t) : NaN) }
        value: Number(section.p.overscan_frame_number)
        gestureKey: "overscan_frame_number"
        available: section.usable
        reason: section.offReason
        onMoved: function(v) { section.set("overscan_frame_number", Math.round(v)) }
    }

    Text {
        Layout.fillWidth: true
        Layout.topMargin: 6
        text: L10n.tr("filmEdge.light")
        color: Theme.dim
        font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
        opacity: section.on ? 1 : Theme.disabledOpacity
    }
    ScrubSlider {
        label: L10n.tr("filmEdge.fog")
        from: 0; to: 4; defaultValue: 1
        step: 0.05; snap: 0.25; decimals: 1
        value: Number(section.p.overscan_fog)
        gestureKey: "overscan_fog"
        available: section.usable
        reason: section.offReason
        onMoved: function(v) { section.set("overscan_fog", v) }
    }
    ScrubSlider {
        label: L10n.tr("filmEdge.leaks")
        from: 0; to: 4; defaultValue: 0
        step: 0.05; snap: 0.25; decimals: 1
        value: Number(section.p.overscan_leaks)
        gestureKey: "overscan_leaks"
        available: section.usable
        reason: section.offReason
        onMoved: function(v) { section.set("overscan_leaks", v) }
    }
    Note {
        text: section.edge.fNumber > 0 ? L10n.tr("filmEdge.lensExif", [String(Math.round(section.edge.fNumber * 10) / 10)])
                                       : L10n.tr("filmEdge.lensAssumed")
        opacity: section.on ? 1 : Theme.disabledOpacity
    }
    Note {
        visible: section.edge.edgeText !== undefined && section.edge.edgeText.length > 0
        text: L10n.tr("filmEdge.edgePrint", [section.edge.edgeText])
        opacity: section.on ? 1 : Theme.disabledOpacity
    }
}
