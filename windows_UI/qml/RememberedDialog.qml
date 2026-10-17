import QtQuick

// A file or folder dialog made afresh for each opening, so it opens where it
// is told. Qt applies a dialog's currentFolder only on its first show
// (QQuickFolderDialog/QQuickFileDialog::onShow, m_firstShow): one dialog
// reused for the session opens wherever it was last left, whatever folder is
// set for it afterwards.
//
//   dialog         the FileDialog or FolderDialog, as a Component
//   folder()       the folder to open in (an empty url: the dialog's default)
//   shown          whether the dialog is up
//   openRemembered()  make it, point it at folder(), open it
Loader {
    id: loader
    property Component dialog
    property var folder: function() { return "" }
    readonly property bool shown: item !== null && item.visible
    active: false
    sourceComponent: dialog
    function openRemembered() {
        active = true
        const start = folder()
        if (start.toString() !== "") item.currentFolder = start
        item.open()
    }
    Connections {
        target: loader.item
        // Later, not now: accepted() may still be on its way, and its handler
        // reads the dialog's selection.
        function onVisibleChanged() { if (!loader.item.visible) Qt.callLater(function() { if (loader.item && !loader.item.visible) loader.active = false }) }
    }
}
