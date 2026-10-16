import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The tool bar over the canvas: import, export, crop, undo/redo on the left;
// the scale and Fit / 100% on the right. "undoButton" and "redoButton" are
// found by name by the --self-test (main.cpp).
Rectangle {
    id: bar
    required property EditorState editor
    Layout.fillWidth: true; implicitHeight: Theme.topHeight; color: Theme.card
    RowLayout {
        anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 6
        ActionButton { text: L10n.tr("toolbar.importRaw"); enabled: bar.editor.canBrowse; onClicked: bar.editor.importRequested(); implicitHeight: 27 }
        ActionButton { text: L10n.tr("toolbar.export"); enabled: bar.editor.canExport; onClicked: bar.editor.openExport(); implicitHeight: 27 }
        ActionButton { text: L10n.tr("toolbar.crop"); accented: bar.editor.cropMode; enabled: bar.editor.canEditCrop; onClicked: bar.editor.toggleCrop(); implicitHeight: 27 }
        ActionButton { objectName: "undoButton"; text: L10n.tr("toolbar.undo"); enabled: preview.settingsEditable && preview.canUndo && !bar.editor.cropMode; onClicked: preview.undo(); implicitHeight: 27; ToolTip.visible: hovered; ToolTip.text: L10n.tr("toolbar.undoHelp") }
        ActionButton { objectName: "redoButton"; text: L10n.tr("toolbar.redo"); enabled: preview.settingsEditable && preview.canRedo && !bar.editor.cropMode; onClicked: preview.redo(); implicitHeight: 27; ToolTip.visible: hovered; ToolTip.text: L10n.tr("toolbar.redoHelp") }
        Item { Layout.fillWidth: true }
        Text { text: preview.hasFrame ? bar.editor.scalePercent.toFixed(1) + "%" : ""; color: Theme.muted; font.pixelSize: 10; horizontalAlignment: Text.AlignRight }
        ActionButton { text: L10n.tr("action.fit"); accented: bar.editor.fit; enabled: preview.hasFrame; onClicked: bar.editor.resetView(true); implicitHeight: 27 }
        ActionButton { text: "100%"; accented: !bar.editor.fit; enabled: preview.hasFrame && !bar.editor.cropMode; onClicked: bar.editor.resetView(false); implicitHeight: 27 }
    }
}
