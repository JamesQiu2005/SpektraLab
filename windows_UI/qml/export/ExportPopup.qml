import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Export options: format, JPEG quality and output size (kept in EditorState so
// the save dialogs use them), then export the displayed frame or the selected
// photos. The file dialogs belong to Main.qml; this asks for them.
//
// Drawn as a rail card with the rail's own rows and pills. The Mac's export
// is a page of its own (recipes, naming, colour spaces, a proof); what that
// needs from the engine and the writer is not on Windows yet, so this keeps
// the options Windows has, in the Mac's style.
Popup {
    id: exportPopup
    required property EditorState editor
    signal exportCurrentRequested()
    signal exportBatchRequested()
    anchors.centerIn: parent
    width: 460; padding: 20
    modal: true; focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: Rectangle { color: Theme.card; border.color: Theme.ruleRegion; radius: 8 }
    contentItem: ColumnLayout {
        spacing: Theme.rowSpacing + 3
        Text {
            text: L10n.tr("export.title")
            color: Theme.text
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontRail + 2; font.weight: Theme.weightTitle
        }
        Note { text: L10n.tr("export.intro") }
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.rule }
        ParamRow {
            label: L10n.tr("export.format")
            labelWidth: 100
            PillDropdown {
                model: [L10n.tr("export.format.tiff16"), L10n.tr("export.format.png8"), L10n.tr("export.format.png16"), L10n.tr("export.format.jpeg8")]
                // Reads `model` so a language switch re-runs the binding (i18n/README.md).
                currentIndex: { model; return exportPopup.editor.exportFormat }
                onActivated: function(index) { exportPopup.editor.exportFormat = index }
            }
        }
        ScrubSlider {
            visible: exportPopup.editor.exportFormat === 3
            label: L10n.tr("export.quality")
            labelWidth: 100
            from: 1; to: 100; defaultValue: 95; step: 1; snap: 5; decimals: 0
            value: exportPopup.editor.exportQuality
            onMoved: function(v) { exportPopup.editor.exportQuality = Math.round(v) }
        }
        ParamRow {
            label: L10n.tr("export.size")
            labelWidth: 100
            PillDropdown {
                model: [L10n.tr("export.size.original"), L10n.tr("export.size.longEdge", [3840]), L10n.tr("export.size.longEdge", [2560]), L10n.tr("export.size.longEdge", [1920]), L10n.tr("export.size.longEdge", [1080])]
                readonly property var sizes: [0, 3840, 2560, 1920, 1080]
                // Reads `model` so a language switch re-runs the binding.
                currentIndex: { model; return Math.max(0, sizes.indexOf(exportPopup.editor.exportLongEdge)) }
                onActivated: function(index) { exportPopup.editor.exportLongEdge = sizes[index] }
            }
        }
        Note { text: L10n.tr("export.sizeNote") }
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.rule }
        ActionButton {
            Layout.fillWidth: true
            accented: true
            text: L10n.tr("export.displayed")
            enabled: preview.hasFrame && !preview.busy
            onClicked: { exportPopup.exportCurrentRequested(); exportPopup.close() }
        }
        ActionButton {
            Layout.fillWidth: true
            text: L10n.tr("export.selected", [preview.selectedCount])
            enabled: preview.selectedCount > 0 && !preview.busy
            onClicked: { exportPopup.exportBatchRequested(); exportPopup.close() }
        }
        Note { text: L10n.tr("export.note") }
        ActionButton {
            Layout.alignment: Qt.AlignRight
            text: L10n.tr("action.cancel")
            onClicked: exportPopup.close()
        }
    }
}
