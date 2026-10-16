import QtQuick
import QtQuick.Layouts
import SpektraLab.Native 1.0

// The centre column: tool bar, canvas, status line and filmstrip, top to
// bottom. It exposes the canvas so Main.qml can hand it to EditorState.
Rectangle {
    id: pane
    required property EditorState editor
    readonly property FrameCanvas canvas: canvasView.canvas
    Layout.fillWidth: true; Layout.fillHeight: true; color: Theme.ground
    ColumnLayout {
        anchors.fill: parent; spacing: 0
        TopBar { editor: pane.editor }
        CanvasView { id: canvasView; editor: pane.editor }
        StatusBar {}
        Filmstrip { editor: pane.editor }
    }
}
