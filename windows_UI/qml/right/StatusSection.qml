import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Status (Windows only): the controller's status line, whether this photo's
// settings are saved, persistence warnings, batch export progress with its
// stop, and the retry after a failed preview. A compact footer under the
// Parameters rail rather than a section, because it reports on operations
// and must not scroll out of sight while a batch runs or a save fails.
//
// The status text comes from C++ (PreviewController through the Localizer's
// tables). "savedStatusNote" and "persistenceWarningNote" keep their names.
Rectangle {
    id: footer
    required property EditorState editor
    Layout.fillWidth: true
    implicitHeight: column.implicitHeight + 16
    color: Theme.card
    Rectangle { width: parent.width; height: 1; color: Theme.rule }
    ColumnLayout {
        id: column
        x: Theme.rowInset; y: 8
        width: parent.width - 2 * Theme.rowInset
        spacing: 4
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            Text {
                text: preview.batchExporting ? L10n.tr("status.batchExport") : preview.failed ? L10n.tr("status.failed") : L10n.tr("status.title")
                color: preview.failed ? Theme.warning : Theme.secondaryText
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightTitle
            }
            Text {
                Layout.fillWidth: true
                text: footer.editor.closePending ? L10n.tr("status.closing") : preview.status
                elide: Text.ElideRight
                color: preview.failed ? Theme.warning : Theme.dim
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
                HoverHandler { id: statusHover }
                ToolTip.visible: statusHover.hovered && truncated
                ToolTip.text: text
            }
        }
        Note { objectName: "savedStatusNote"; text: preview.savedStatus; visible: text.length > 0 }
        Note { objectName: "persistenceWarningNote"; text: preview.persistenceWarning; visible: text.length > 0; color: Theme.warning }
        ProgressBar {
            Layout.fillWidth: true
            visible: preview.batchExporting
            from: 0; to: Math.max(1, preview.batchTotal); value: preview.batchProgress
            background: Rectangle { implicitHeight: 4; radius: 2; color: Theme.plot }
            contentItem: Item {
                implicitHeight: 4
                Rectangle { width: parent.width * (preview.batchProgress / Math.max(1, preview.batchTotal)); height: parent.height; radius: 2; color: Theme.accent }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            visible: preview.batchExporting || (preview.failed && preview.hasFrame)
            spacing: 8
            PillButton {
                visible: preview.batchExporting
                text: L10n.tr("status.stopBatch")
                onClicked: preview.cancelExport()
            }
            PillButton {
                visible: preview.failed && preview.hasFrame && !preview.batchExporting
                text: L10n.tr("status.retryPreview")
                available: !preview.busy
                onClicked: preview.apply()
            }
            Item { Layout.fillWidth: true }
        }
    }
}
