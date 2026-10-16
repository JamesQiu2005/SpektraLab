import QtQuick
import QtQuick.Layouts
import SpektraLab.Native 1.0

// Navigator: the whole displayed frame in miniature, a Fit button and the
// canvas's current scale.
Section {
    id: section
    required property EditorState editor
    title: L10n.tr("navigator.title")
    Rectangle {
        Layout.fillWidth: true; Layout.preferredHeight: 132; color: Theme.wellDark
        FrameCanvas { anchors.fill: parent; anchors.margins: 6; image: preview.previewImage; enabled: false }
        Text { anchors.centerIn: parent; visible: !preview.hasFrame; text: L10n.tr("navigator.empty"); color: Theme.muted; font.pixelSize: 11 }
    }
    RowLayout {
        ActionButton { text: L10n.tr("action.fit"); implicitHeight: 23; enabled: preview.hasFrame; onClicked: section.editor.resetView(true) }
        Item { Layout.fillWidth: true }
        Text { text: preview.hasFrame ? section.editor.scalePercent.toFixed(1) + "%" : ""; color: Theme.muted; font.pixelSize: 10 }
    }
}
