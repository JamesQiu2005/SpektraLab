import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import SpektraLab.Native 1.0

// One licence text, in full, selectable and scrollable (AboutWindow.swift
// `LicenceSheet`): read from the licenses folder beside the executable, never
// retyped -- a text that drifts from the file beside it is worse than none.
// Shown in the app rather than handed to Notepad, so the obligation (the text
// is available) does not depend on another program.
//
//   showFile(file, heading)   load licenses/<file> and present the window
ShellWindow {
    id: viewer
    objectName: "licenceWindow"
    title: heading
    width: 700; height: 580
    minimumWidth: 420; minimumHeight: 300
    property string file
    property string heading
    property string body

    function showFile(name, title) {
        file = name
        heading = title
        var text = AppInfo.licenceText(name)
        body = text.length > 0 ? text : L10n.tr("about.licenceMissing", [name])
        textArea.cursorPosition = 0
        present()
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 10
        Text {
            Layout.fillWidth: true
            text: viewer.heading
            elide: Text.ElideRight
            color: Theme.text
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontTitle; font.weight: Theme.weightTitle
        }
        ScrollView {
            id: scroll
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            ScrollBar.vertical: RailScrollBar { parent: scroll; x: scroll.width - width; height: scroll.availableHeight }
            background: Rectangle { color: Theme.plot; radius: 4 }
            TextArea {
                id: textArea
                text: viewer.body
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.Wrap
                color: Theme.secondaryText
                selectionColor: Theme.accent
                selectedTextColor: Theme.selectionInk
                font.family: "Consolas"; font.pixelSize: 11
                padding: 10
                background: null
            }
        }
        RowLayout {
            Layout.fillWidth: true
            LinkText {
                text: L10n.tr("settings.showInExplorer")
                onClicked: AppInfo.openFolder(AppInfo.licencesDirectory)
            }
            Item { Layout.fillWidth: true }
            PillButton {
                text: L10n.tr("about.done")
                onClicked: viewer.close()
            }
        }
    }
}
