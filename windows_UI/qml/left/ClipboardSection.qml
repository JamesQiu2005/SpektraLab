import QtQuick
import QtQuick.Layouts

// Settings Clipboard (ClipboardSection.swift, RFC-027), folded by default:
// the Mac's seven groups a copy takes, what the clipboard holds, Copy and
// Paste, and Sync to the picked photos.
//
// Sync is live -- it is the Windows controller's syncSelectedSettings, the
// same action as the filmstrip's Sync button, and copies this photo's film,
// paper, decode and effects (not the crop) to the selected photos. Choosing
// groups, Copy and Paste need a settings clipboard in the controller and are
// greyed with the reason until a lane adds it.
MacSection {
    id: section
    required property EditorState editor
    sectionId: "clipboard"
    title: L10n.tr("clipboard.title")
    defaultExpanded: false

    Repeater {
        model: [L10n.tr("clipboard.filmAndPaper"), L10n.tr("clipboard.exposure"), L10n.tr("clipboard.whiteBalance"),
                L10n.tr("clipboard.filmEffects"), L10n.tr("clipboard.printEffects"), L10n.tr("clipboard.scenePlacement"),
                L10n.tr("clipboard.masks")]
        delegate: CheckRow {
            required property string modelData
            label: modelData
            available: false
            reason: L10n.tr("placeholder.clipboard")
        }
    }
    Note { text: L10n.tr("clipboard.empty") }
    RowLayout {
        spacing: 8
        PillButton { text: L10n.tr("clipboard.copy"); available: false; reason: L10n.tr("placeholder.clipboard") }
        PillButton { text: L10n.tr("clipboard.paste"); available: false; reason: L10n.tr("placeholder.clipboard") }
        Item { Layout.fillWidth: true }
    }
    RowLayout {
        PillButton {
            text: preview.selectedCount > 0 ? L10n.tr("clipboard.syncTo", [preview.selectedCount]) : L10n.tr("clipboard.sync")
            available: section.editor.canBrowse && preview.hasFrame && preview.selectedCount > 0
            toolTip: L10n.tr("strip.syncHelp")
            reason: L10n.tr("clipboard.syncReason")
            onClicked: preview.syncSelectedSettings(false)
        }
        Item { Layout.fillWidth: true }
    }
}
