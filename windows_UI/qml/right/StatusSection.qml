import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Status: the controller's status line, saved/persistence notes, batch export
// progress and the retry after a failed preview. The status text itself comes
// from C++ (PreviewController) and is not localised here.
Section {
    id: section
    required property EditorState editor
    title: preview.batchExporting ? L10n.tr("status.batchExport") : preview.failed ? L10n.tr("status.failed") : L10n.tr("status.title")
    Note { text: section.editor.closePending ? L10n.tr("status.closing") : preview.status; color: preview.failed ? "#ffb39f" : Theme.muted }
    Note { objectName: "savedStatusNote"; text: preview.savedStatus; visible: text.length > 0 }
    Note { objectName: "persistenceWarningNote"; text: preview.persistenceWarning; visible: text.length > 0; color: "#ffb39f" }
    ProgressBar { Layout.fillWidth: true; visible: preview.batchExporting; from: 0; to: Math.max(1, preview.batchTotal); value: preview.batchProgress }
    ActionButton { Layout.fillWidth: true; text: L10n.tr("status.stopBatch"); visible: preview.batchExporting; onClicked: preview.cancelExport() }
    ActionButton { Layout.fillWidth: true; text: L10n.tr("status.retryPreview"); visible: preview.failed && preview.hasFrame && !preview.batchExporting; enabled: !preview.busy; onClicked: preview.apply() }
}
