import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Status: the controller's status line, saved/persistence notes, batch export
// progress and the retry after a failed preview. The status text itself comes
// from C++ (PreviewController) and is not localised here.
Section {
    id: section
    required property EditorState editor
    title: preview.batchExporting ? "批量导出" : preview.failed ? "无法完成操作" : "状态"
    Note { text: section.editor.closePending ? "等待当前操作完成后关闭…" : preview.status; color: preview.failed ? "#ffb39f" : Theme.muted }
    Note { objectName: "savedStatusNote"; text: preview.savedStatus; visible: text.length > 0 }
    Note { objectName: "persistenceWarningNote"; text: preview.persistenceWarning; visible: text.length > 0; color: "#ffb39f" }
    ProgressBar { Layout.fillWidth: true; visible: preview.batchExporting; from: 0; to: Math.max(1, preview.batchTotal); value: preview.batchProgress }
    ActionButton { Layout.fillWidth: true; text: "当前照片完成后停止"; visible: preview.batchExporting; onClicked: preview.cancelExport() }
    ActionButton { Layout.fillWidth: true; text: "重新尝试预览"; visible: preview.failed && preview.hasFrame && !preview.batchExporting; enabled: !preview.busy; onClicked: preview.apply() }
}
