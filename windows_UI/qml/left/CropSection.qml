import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Crop: aspect presets, the drag-to-crop editor, quarter turns, flips and
// straightening. All of it is post-render geometry; none re-develops.
Section {
    id: section
    required property EditorState editor
    title: L10n.tr("crop.title")
    RowLayout {
        Layout.fillWidth: true
        ComboBox {
            id: cropAspect; Layout.fillWidth: true
            // Only "Free" is copy; ratios are not translated (i18n/README.md).
            model: [L10n.tr("crop.aspect.free"), "1:1", "3:2", "4:3", "16:9"]; enabled: section.editor.canEditCrop
            currentIndex: {
                // Read `model` so a language switch, which replaces the model
                // and with it resets the index to 0, re-runs this binding.
                model
                var c = preview.cropRect
                if (!preview.hasFrame || (c.x === 0 && c.y === 0 && c.width === 1 && c.height === 1)) return 0
                var ratio = c.width * preview.metadata.sourceWidth / (c.height * preview.metadata.sourceHeight)
                if (preview.quarterTurns % 2 !== 0) ratio = 1 / ratio
                var values = [0, 1, 1.5, 4 / 3, 16 / 9]
                for (var i = 1; i < values.length; ++i)
                    if (Math.abs(ratio - values[i]) < 0.002) return i
                return 0
            }
            onActivated: { section.editor.cropMode = false; preview.setCropAspect([0, 1, 1.5, 4 / 3, 16 / 9][currentIndex]); section.editor.resetView(true) }
        }
        ActionButton { text: L10n.tr("action.reset"); enabled: section.editor.canEditCrop; onClicked: { section.editor.cropMode = false; preview.resetCrop(); section.editor.resetView(true) } }
    }
    ActionButton { Layout.fillWidth: true; text: section.editor.cropMode ? L10n.tr("crop.finish") : L10n.tr("crop.dragToCrop"); accented: section.editor.cropMode; enabled: section.editor.canEditCrop; onClicked: section.editor.toggleCrop() }
    Note { text: section.editor.cropMode ? L10n.tr("crop.editingNote") : L10n.tr("crop.sharedNote") }
    RowLayout {
        Layout.fillWidth: true
        ActionButton { objectName: "rotateLeftButton"; Layout.fillWidth: true; text: L10n.tr("crop.rotateLeft"); enabled: section.editor.canEditCrop && !section.editor.cropMode; onClicked: { preview.rotateCounterClockwise(); section.editor.resetView(true) } }
        ActionButton { objectName: "rotateRightButton"; Layout.fillWidth: true; text: L10n.tr("crop.rotateRight"); enabled: section.editor.canEditCrop && !section.editor.cropMode; onClicked: { preview.rotateClockwise(); section.editor.resetView(true) } }
    }
    RowLayout {
        Layout.fillWidth: true
        ActionButton { objectName: "flipHorizontalButton"; Layout.fillWidth: true; text: L10n.tr("crop.flipHorizontal"); accented: preview.flipHorizontal; enabled: section.editor.canEditCrop && !section.editor.cropMode; onClicked: preview.setFlipHorizontal(!preview.flipHorizontal) }
        ActionButton { objectName: "flipVerticalButton"; Layout.fillWidth: true; text: L10n.tr("crop.flipVertical"); accented: preview.flipVertical; enabled: section.editor.canEditCrop && !section.editor.cropMode; onClicked: preview.setFlipVertical(!preview.flipVertical) }
    }
    RowLayout {
        Layout.fillWidth: true
        Text { text: L10n.tr("crop.straighten"); color: Theme.text; font.pixelSize: 11 }
        Item { Layout.fillWidth: true }
        Text { text: (straightenSlider.pressed ? straightenSlider.from + straightenSlider.position * (straightenSlider.to - straightenSlider.from) : preview.straightenDegrees).toFixed(1) + "°"; color: Theme.muted; font.pixelSize: 10 }
    }
    Slider {
        id: straightenSlider; objectName: "straightenSlider"
        Layout.fillWidth: true; implicitHeight: 24
        from: -45; to: 45; stepSize: 0.1; live: false
        value: preview.straightenDegrees
        enabled: section.editor.canEditCrop && !section.editor.cropMode
        // Applied on release: a straighten re-samples the 16-bit source, so
        // the drag shows only the number and the release commits it.
        onPressedChanged: {
            if (pressed) preview.beginEditGesture("straightenDegrees")
            else {
                preview.setStraightenDegrees(Math.round((from + position * (to - from)) * 10) / 10)
                preview.endEditGesture()
            }
        }
        onMoved: { if (!pressed) preview.setStraightenDegrees(value) }
    }
    Note { text: L10n.tr("crop.straightenNote") }
    ActionButton { objectName: "resetGeometryButton"; Layout.fillWidth: true; text: L10n.tr("crop.resetGeometry"); enabled: section.editor.canEditCrop && !section.editor.cropMode; onClicked: { preview.resetGeometry(); section.editor.resetView(true) } }
}
