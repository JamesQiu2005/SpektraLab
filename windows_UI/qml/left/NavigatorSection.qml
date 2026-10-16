import QtQuick
import QtQuick.Layouts
import SpektraLab.Native 1.0

// Navigator (NavigatorSection.swift): the frame in miniature in a well a step
// darker than the plot ground, and Fit. Past fit the part of the frame on the
// canvas is framed and the rest dimmed, and a click or drag in the well puts
// that point at the canvas's centre.
//
// It shows the canvas's frame -- the cropped print, or the whole source
// while the crop editor is up -- so it cannot show a different frame from
// the canvas (the Mac's trap 33). Outside the crop editor that is the
// controller's navigator image, the same visible frame reduced to 1024 px,
// rather than a second full-resolution texture (251 MiB of RGBA16F at 33 MP).
MacSection {
    id: section
    required property EditorState editor
    sectionId: "navigator"
    title: L10n.tr("navigator.title")
    inset: false

    Item {
        Layout.fillWidth: true
        Layout.preferredHeight: Theme.navigatorHeight
        Rectangle {
            id: well
            x: Theme.navigatorInset; width: parent.width - 2 * Theme.navigatorInset
            height: parent.height
            color: Theme.navigatorWell
            FrameCanvas {
                id: thumb
                anchors.fill: parent
                image: section.editor.cropMode && section.editor.canvas ? section.editor.canvas.image
                                                                       : preview.navigatorImage
                // Graded like the canvas (Post-Dev), each pixel at its place
                // on the source: the navigator image is the cropped print.
                postDev: section.editor.cropMode && section.editor.canvas ? section.editor.canvas.postDev : preview.canvasPostDev
                sourceMap: section.editor.cropMode ? [] : preview.postDevSourceMap
                enabled: false
            }
            // Everything off the canvas dimmed, what is on it framed.
            Item {
                id: seen
                visible: preview.hasFrame && !section.editor.fit
                readonly property rect p: thumb.imageRect
                readonly property rect v: section.editor.visibleFraction
                x: p.x + v.x * p.width; y: p.y + v.y * p.height
                width: v.width * p.width; height: v.height * p.height
                Rectangle { x: seen.p.x - seen.x; y: seen.p.y - seen.y; width: seen.p.width; height: Math.max(0, -y); color: "#73000000" }
                Rectangle { x: seen.p.x - seen.x; y: seen.height; width: seen.p.width; height: Math.max(0, seen.p.y + seen.p.height - seen.y - seen.height); color: "#73000000" }
                Rectangle { x: seen.p.x - seen.x; y: 0; width: Math.max(0, -x); height: seen.height; color: "#73000000" }
                Rectangle { x: seen.width; y: 0; width: Math.max(0, seen.p.x + seen.p.width - seen.x - seen.width); height: seen.height; color: "#73000000" }
                Rectangle { anchors.fill: parent; color: "transparent"; border.color: Theme.text; border.width: 1 }
            }
            Text {
                anchors.centerIn: parent
                visible: !preview.hasFrame
                text: L10n.tr("navigator.empty")
                color: Theme.dim
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
            }
            MouseArea {
                anchors.fill: parent
                enabled: preview.hasFrame && !section.editor.fit
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                function centre(mouse) {
                    var p = thumb.imageRect
                    if (p.width <= 0 || p.height <= 0) return
                    section.editor.centreOn(Math.max(0, Math.min(1, (mouse.x - p.x) / p.width)),
                                            Math.max(0, Math.min(1, (mouse.y - p.y) / p.height)))
                }
                onPressed: function(mouse) { centre(mouse) }
                onPositionChanged: function(mouse) { if (pressed) centre(mouse) }
            }
        }
    }
    Item {
        Layout.fillWidth: true
        Layout.preferredHeight: Theme.controlHeight
        Layout.topMargin: 2
        PillButton {
            x: Theme.navigatorInset
            text: L10n.tr("action.fit")
            available: preview.hasFrame && !section.editor.fit
            toolTip: L10n.tr("action.fit") + " (Ctrl+0)"
            onClicked: section.editor.resetView(true)
        }
        Text {
            anchors.right: parent.right; anchors.rightMargin: Theme.navigatorInset
            anchors.verticalCenter: parent.verticalCenter
            text: preview.hasFrame ? section.editor.scalePercent.toFixed(1) + " %" : ""
            color: Theme.dim
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
        }
    }
}
