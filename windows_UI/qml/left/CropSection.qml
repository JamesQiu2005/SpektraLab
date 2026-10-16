import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Crop (CropSection.swift): aspect and which way up, straighten, quarter
// turns and flips, and what the crop costs in pixels. All of it is
// post-render geometry; none of it re-develops.
//
// The drag-to-crop editor is the tool bar's crop tool (and Enter / Esc);
// while it is up the rows here wait, as the Mac's do while its crop tool owns
// the frame. Straightening re-samples the 16-bit source, so it applies on
// release; the number follows the drag.
MacSection {
    id: section
    required property EditorState editor
    sectionId: "crop"
    title: L10n.tr("crop.title")
    // While a film edge is on, it frames the picture in its gate: the crop is
    // the Film Edge section's Framing, and these rows wait (CropSection.swift
    // :32-54, "Held by Film Edge").
    readonly property bool held: preview.parameters.overscan_active === true
    readonly property string heldReason: L10n.tr("crop.heldReason")
    readonly property string waitReason: held ? heldReason : editor.cropMode ? L10n.tr("crop.waitForEditor") : ""
    caption: held ? L10n.tr("crop.heldByFilmEdge") : ""
    readonly property bool usable: editor.canEditCrop && !editor.cropMode && !held
    // Ratios describe the displayed result, after any quarter turn (the
    // controller's convention); 0 is Free.
    readonly property var ratios: [0, 1, 1.5, 4 / 3, 16 / 9]
    readonly property real shownRatio: {
        var c = preview.cropRect
        if (!preview.hasFrame || c.height <= 0 || preview.metadata.sourceHeight === undefined) return 0
        var r = c.width * preview.metadata.sourceWidth / (c.height * preview.metadata.sourceHeight)
        return preview.quarterTurns % 2 !== 0 ? 1 / r : r
    }
    readonly property bool fullFrame: {
        var c = preview.cropRect
        return c.x === 0 && c.y === 0 && c.width === 1 && c.height === 1
    }
    readonly property int aspectIndex: {
        if (!preview.hasFrame || fullFrame) return 0
        var r = shownRatio >= 1 ? shownRatio : 1 / shownRatio
        for (var i = 1; i < ratios.length; ++i)
            if (Math.abs(r - ratios[i]) < 0.002) return i
        return 0
    }
    readonly property bool portrait: aspectIndex > 1 && shownRatio < 1

    function setAspect(index, upright) {
        editor.cropMode = false
        var r = ratios[index]
        preview.setCropAspect(r > 0 && upright ? 1 / r : r)
        editor.resetView(true)
    }

    menuItems: [
        RailMenuItem {
            text: L10n.tr("crop.resetGeometry"); enabled: section.usable
            onTriggered: { preview.resetGeometry(); section.editor.resetView(true) }
        },
        RailMenuItem {
            text: L10n.tr("crop.straightenZero"); enabled: section.usable && preview.straightenDegrees !== 0
            onTriggered: preview.setStraightenDegrees(0)
        },
        MenuSeparator {},
        RailMenuItem {
            text: L10n.tr("crop.wholeFrame"); enabled: section.usable
            onTriggered: { preview.resetCrop(); preview.setStraightenDegrees(0); section.editor.resetView(true) }
        }
    ]

    ParamRow {
        label: L10n.tr("crop.aspect")
        available: section.usable
        reason: section.waitReason
        // The ratio pill takes the slot less the orientation button's room.
        Item {
            width: parent.width - orientationButton.width - 6
            height: parent.height
            PillDropdown {
                // Only "Free" is copy; ratios are not translated (i18n/README.md).
                model: [L10n.tr("crop.aspect.free"), "1:1", "3:2", "4:3", "16:9"]
                // Reads `model` so a language switch, which replaces the model
                // and resets the index to 0, re-runs this binding.
                currentIndex: { model; return section.aspectIndex }
                onActivated: function(index) { section.setAspect(index, section.portrait) }
            }
        }
        // Which way up: the Mac's rectangle / rectangle.portrait, drawn, since
        // neither system icon font has a plain rectangle glyph.
        IconButton {
            id: orientationButton
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            size: 22
            available: section.usable && section.aspectIndex > 1
            Rectangle {
                anchors.centerIn: parent
                width: section.portrait ? 8 : 12; height: section.portrait ? 12 : 8
                radius: 1
                color: "transparent"
                border.width: 1; border.color: Theme.text
                opacity: orientationButton.available ? 1 : 0.4
            }
            toolTip: section.portrait ? L10n.tr("crop.orientation.upright") : L10n.tr("crop.orientation.across")
            reason: L10n.tr("crop.orientation.none")
            onClicked: section.setAspect(section.aspectIndex, !section.portrait)
        }
    }
    ScrubSlider {
        label: L10n.tr("crop.straighten")
        sublabel: L10n.tr("crop.straightenUnit")
        bodyObjectName: "straightenSlider"
        from: -45; to: 45; defaultValue: 0
        step: 0.1; snap: 1; decimals: 1; signed: true; suffix: "°"
        value: preview.straightenDegrees
        live: false
        gestureKey: "straightenDegrees"
        available: section.usable
        toolTip: L10n.tr("crop.straightenNote")
        reason: section.waitReason
        onMoved: function(v) { preview.setStraightenDegrees(Math.round(v * 10) / 10) }
    }
    ParamRow {
        label: L10n.tr("crop.rotate")
        available: section.usable
        reason: section.waitReason
        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4
            IconButton {
                buttonObjectName: "rotateLeftButton"
                size: 22; glyphSize: 13
                glyph: Icons.rotate; mirrored: true
                toolTip: L10n.tr("crop.rotateLeft")
                onClicked: { preview.rotateCounterClockwise(); section.editor.resetView(true) }
            }
            IconButton {
                buttonObjectName: "rotateRightButton"
                size: 22; glyphSize: 13
                glyph: Icons.rotate
                toolTip: L10n.tr("crop.rotateRight")
                onClicked: { preview.rotateClockwise(); section.editor.resetView(true) }
            }
            IconButton {
                buttonObjectName: "flipHorizontalButton"
                size: 22; glyphSize: 13
                glyph: Icons.flip
                active: preview.flipHorizontal
                toolTip: L10n.tr("crop.flipHorizontal")
                onClicked: preview.setFlipHorizontal(!preview.flipHorizontal)
            }
            IconButton {
                buttonObjectName: "flipVerticalButton"
                size: 22; glyphSize: 13
                glyph: Icons.flip; glyphRotation: 90
                active: preview.flipVertical
                toolTip: L10n.tr("crop.flipVertical")
                onClicked: preview.setFlipVertical(!preview.flipVertical)
            }
        }
    }
    // What the crop actually costs, in the units a photographer cares about:
    // the number goes down as the straightening goes up.
    Note {
        text: {
            if (!preview.hasFrame) return "—"
            var w = preview.metadata.width, h = preview.metadata.height
            var whole = section.fullFrame && preview.straightenDegrees === 0
            return w + " × " + h + "  ·  " + (whole ? L10n.tr("crop.fullFrame") : (w * h / 1e6).toFixed(1) + " MP")
        }
    }
    Note {
        visible: section.editor.cropMode
        text: L10n.tr("crop.editingNote")
        color: Theme.accent
    }
}
