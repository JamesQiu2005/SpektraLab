import QtQuick
import QtQuick.Layouts

// Photo Info: camera, size, decode and the last render's cost, and the reset
// for this photo's settings.
Section {
    title: L10n.tr("info.title")
    Note { text: preview.hasFrame ? preview.metadata.camera : L10n.tr("info.noPhoto"); color: Theme.text }
    Note { text: preview.hasFrame ? L10n.tr("info.pixels", [preview.metadata.width, preview.metadata.height]) + "\n" + (preview.metadata.mode === "headroom" ? L10n.tr("info.decodeHeadroom") : L10n.tr("info.decodeCompatible")) : "" }
    Note { text: preview.hasFrame ? L10n.tr("info.renderTime", [(preview.metadata.renderMs / 1000).toFixed(2)]) + " · " + (preview.metadata.cached ? L10n.tr("info.reusedNegative") : L10n.tr("info.fullRender")) : "" }
    ActionButton { Layout.fillWidth: true; text: L10n.tr("info.resetPhoto"); enabled: preview.settingsEditable; onClicked: preview.resetSettings() }
}
