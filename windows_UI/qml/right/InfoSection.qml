import QtQuick

// Photo Info (Windows only): camera, size, decode and the last render's
// cost, in three caption lines. Resetting this photo's settings is the
// header's arrow (and the filmstrip's context menu, where the Mac has it).
MacSection {
    sectionId: "photoInfo"
    title: L10n.tr("info.title")
    caption: preview.hasFrame ? "" : L10n.tr("info.noPhoto")
    resetVisible: true
    resetAvailable: preview.settingsEditable && preview.hasFrame
    resetToolTip: L10n.tr("info.resetPhoto")
    onResetRequested: preview.resetSettings()

    Note {
        visible: preview.hasFrame
        color: Theme.secondaryText
        text: preview.hasFrame ? preview.metadata.camera : ""
    }
    Note {
        visible: preview.hasFrame
        text: preview.hasFrame
            ? L10n.tr("info.pixels", [preview.metadata.width, preview.metadata.height]) + "  ·  "
              + (preview.metadata.mode === "headroom" ? L10n.tr("info.decodeHeadroom") : L10n.tr("info.decodeCompatible")) + "\n"
              + L10n.tr("info.renderTime", [(preview.metadata.renderMs / 1000).toFixed(2)]) + "  ·  "
              + (preview.metadata.cached ? L10n.tr("info.reusedNegative") : L10n.tr("info.fullRender"))
            : ""
    }
}
