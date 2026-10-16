import QtQuick
import QtQuick.Layouts
import SpektraLab.Native 1.0

// The centre column (EditorWindow.swift `centreColumn`): the tool bar, the
// canvas and the filmstrip, separated by the darker region hairline. It
// exposes the canvas so Main.qml can hand it to EditorState.
Rectangle {
    id: pane
    required property EditorState editor
    readonly property FrameCanvas canvas: canvasView.canvas
    Layout.fillWidth: true; Layout.fillHeight: true
    color: Theme.ground
    ColumnLayout {
        anchors.fill: parent; spacing: 0
        TopBar { editor: pane.editor }
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.ruleRegion }
        CanvasView { id: canvasView; editor: pane.editor }
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.ruleRegion; visible: !pane.editor.filmstripCollapsed }
        Filmstrip { editor: pane.editor; visible: !pane.editor.filmstripCollapsed }
    }
}
