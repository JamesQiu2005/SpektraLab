import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Export options: format, JPEG quality and output size (kept in EditorState so
// the save dialogs use them), then export the displayed frame or the selected
// photos. The file dialogs belong to Main.qml; this asks for them.
Popup {
    id: exportPopup
    required property EditorState editor
    signal exportCurrentRequested()
    signal exportBatchRequested()
    anchors.centerIn: parent
    width: 470; padding: 22
    modal: true; focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: Rectangle { color: Theme.card; border.color: Theme.line; radius: 7 }
    contentItem: ColumnLayout {
        spacing: 14
        Text { text: L10n.tr("export.title"); color: Theme.text; font.pixelSize: 20; font.bold: true }
        Note { text: L10n.tr("export.intro") }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line; opacity: 0.5 }
        RowLayout {
            Text { text: L10n.tr("export.format"); color: Theme.text; Layout.preferredWidth: 76 }
            ComboBox {
                Layout.fillWidth: true; model: [L10n.tr("export.format.tiff16"), L10n.tr("export.format.png8"), L10n.tr("export.format.png16"), L10n.tr("export.format.jpeg8")]
                // Reads `model` so a language switch re-runs the binding (see FilmFormatSection).
                currentIndex: { model; return exportPopup.editor.exportFormat }
                onActivated: exportPopup.editor.exportFormat = currentIndex
            }
        }
        RowLayout {
            visible: exportPopup.editor.exportFormat === 3
            Text { text: L10n.tr("export.quality"); color: Theme.text; Layout.preferredWidth: 76 }
            Slider { Layout.fillWidth: true; from: 1; to: 100; stepSize: 1; value: exportPopup.editor.exportQuality; onMoved: exportPopup.editor.exportQuality = value }
            Text { text: exportPopup.editor.exportQuality; color: Theme.muted; Layout.preferredWidth: 28 }
        }
        RowLayout {
            Text { text: L10n.tr("export.size"); color: Theme.text; Layout.preferredWidth: 76 }
            ComboBox {
                Layout.fillWidth: true
                model: [L10n.tr("export.size.original"), L10n.tr("export.size.longEdge", [3840]), L10n.tr("export.size.longEdge", [2560]), L10n.tr("export.size.longEdge", [1920]), L10n.tr("export.size.longEdge", [1080])]
                readonly property var sizes: [0, 3840, 2560, 1920, 1080]
                // Reads `model` so a language switch re-runs the binding (see FilmFormatSection).
                currentIndex: { model; return Math.max(0, sizes.indexOf(exportPopup.editor.exportLongEdge)) }
                onActivated: exportPopup.editor.exportLongEdge = sizes[currentIndex]
            }
        }
        Note { text: L10n.tr("export.sizeNote") }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line; opacity: 0.5 }
        ActionButton { Layout.fillWidth: true; accented: true; text: L10n.tr("export.displayed"); enabled: preview.hasFrame && !preview.busy; onClicked: { exportPopup.exportCurrentRequested(); exportPopup.close() } }
        ActionButton { Layout.fillWidth: true; text: L10n.tr("export.selected", [preview.selectedCount]); enabled: preview.selectedCount > 0 && !preview.busy; onClicked: { exportPopup.exportBatchRequested(); exportPopup.close() } }
        Note { text: L10n.tr("export.note") }
        ActionButton { Layout.alignment: Qt.AlignRight; text: L10n.tr("action.cancel"); onClicked: exportPopup.close() }
    }
}
