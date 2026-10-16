import QtQuick
import QtQuick.Controls

// The application menu: the Mac's menu bar commands (SpektrafilmApp.swift
// `EditorCommands`) that the Windows app can carry out, behind one button at
// the top bar's leading edge. This window has no menu bar -- its top row is
// the Mac's tool bar -- so the commands sit where a Windows user looks for a
// compact app's menu, each with its shortcut beside it.
//
// Left out because Windows cannot do them yet, rather than shown dead in a
// menu: Copy / Paste Settings (the clipboard's groups, ClipboardSection),
// Before / After and Bypass Adjustments, Restart Render Service, the half-
// frame pair, the Mac's frame and crop menus' commands without a Windows
// shortcut, and Reveal Settings in Finder (Settings > Diagnostics shows the
// folders instead).
//
//   editor   the window's EditorState: the gates and the requests the
//            commands share with Main.qml's Shortcuts
Item {
    id: root
    required property EditorState editor
    implicitWidth: button.implicitWidth; implicitHeight: button.implicitHeight

    function toggleFullScreen() {
        var w = root.Window.window
        if (w) w.visibility = w.visibility === Window.FullScreen ? Window.Windowed : Window.FullScreen
    }

    IconButton {
        id: button
        objectName: "appMenuButton"
        glyph: ""     // GlobalNavigationButton: the Windows app menu
        glyphSize: 15
        active: menu.visible
        toolTip: L10n.tr("menu.help")
        onClicked: menu.visible ? menu.close() : menu.popup(button, 0, button.height + 2)
    }
    Connections {
        target: root.editor
        function onAppMenuRequested(open) {
            if (open) menu.popup(button, 0, button.height + 2)
            else menu.close()
        }
    }

    RailMenu {
        id: menu
        objectName: "appMenu"
        MenuCommand { text: L10n.tr("menu.import"); shortcutText: "Ctrl+O"; enabled: root.editor.canBrowse; onTriggered: root.editor.importRequested() }
        MenuCommand { text: L10n.tr("menu.export"); shortcutText: "Ctrl+E"; enabled: root.editor.canExport; onTriggered: root.editor.openExport() }
        MenuSeparator {}
        MenuCommand { text: L10n.tr("menu.undo"); shortcutText: "Ctrl+Z"; enabled: root.editor.canUndo; onTriggered: preview.undo() }
        MenuCommand { text: L10n.tr("menu.redo"); shortcutText: "Ctrl+Y"; enabled: root.editor.canRedo; onTriggered: preview.redo() }
        MenuSeparator {}
        MenuCommand { text: L10n.tr("menu.selectAll"); shortcutText: "Ctrl+A"; enabled: root.editor.canSelectAll; onTriggered: preview.selectAllPhotos(true) }
        MenuCommand { text: L10n.tr("menu.sync"); enabled: root.editor.canSync; onTriggered: preview.syncSelectedSettings(false) }
        MenuCommand { text: L10n.tr("menu.resetPhoto"); enabled: root.editor.canResetPhoto; onTriggered: preview.resetSettings() }
        MenuSeparator {}
        RailMenu {
            title: L10n.tr("menu.view")
            MenuCommand { text: L10n.tr("menu.zoomFit"); shortcutText: "Ctrl+0"; enabled: preview.hasFrame; onTriggered: root.editor.resetView(true) }
            MenuCommand { text: L10n.tr("menu.zoom100"); shortcutText: "Ctrl+1"; enabled: preview.hasFrame && !root.editor.cropMode; onTriggered: root.editor.resetView(false) }
            MenuCommand { text: L10n.tr("menu.zoomIn"); shortcutText: "Ctrl++"; enabled: root.editor.canZoomIn; onTriggered: root.editor.zoomIn() }
            MenuCommand { text: L10n.tr("menu.zoomOut"); shortcutText: "Ctrl+-"; enabled: root.editor.canZoomOut; onTriggered: root.editor.zoomOut() }
            MenuSeparator {}
            MenuCommand { text: L10n.tr("menu.sidePanels"); shortcutText: "Ctrl+B"; onTriggered: root.editor.toggleSidePanels() }
            MenuCommand { text: L10n.tr("menu.filmstrip"); shortcutText: "Ctrl+Shift+F"; onTriggered: root.editor.filmstripCollapsed = !root.editor.filmstripCollapsed }
            MenuCommand { text: L10n.tr("menu.fullScreen"); shortcutText: "F11"; onTriggered: root.toggleFullScreen() }
        }
        MenuSeparator {}
        MenuCommand { text: L10n.tr("menu.settings"); shortcutText: "Ctrl+,"; onTriggered: root.editor.settingsRequested("") }
        MenuCommand { text: L10n.tr("menu.about"); onTriggered: root.editor.aboutRequested() }
        MenuSeparator {}
        MenuCommand { text: L10n.tr("menu.exit"); shortcutText: "Ctrl+Q"; onTriggered: root.editor.quitRequested() }
    }
}
