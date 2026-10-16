import QtQuick
import QtQuick.Layouts

// Settings Clipboard (ClipboardSection.swift, RFC-027), folded by default:
// Capture One's adjustments clipboard with the Mac's seven groups.
//
// The boxes choose what the NEXT copy (and Sync) takes; the line under them
// says what the clipboard HOLDS, which a box changed after copying does not
// alter -- the answer to the report the Mac's section came from ("I can't say
// what got copied"). Copy is Ctrl+Shift+C, Paste Ctrl+Shift+V; Paste goes to
// every selected photo (the open one live, one undo step), Sync to N writes a
// fresh copy of the open photo's ticked groups onto the N other selected
// photos, each with its own undo step. Crop, Post-Dev, Film Edge and Date Back
// stay with each photo; As Shot white balance and Scene Placement are
// resolved on each target (SettingsClipboard.swift). Paste and Sync wait
// for a batch export.
MacSection {
    id: section
    required property EditorState editor
    sectionId: "clipboard"
    title: L10n.tr("clipboard.title")
    defaultExpanded: false
    readonly property var clip: preview.clipboard
    readonly property string lockedReason: clip.locked === true ? L10n.tr("clipboard.locked") : ""
    // ClipboardGroup.title / .help, by the controller's group ids.
    function groupTitle(id) {
        switch (id) {
        case "filmAndPaper": return L10n.tr("clipboard.filmAndPaper")
        case "exposure": return L10n.tr("clipboard.exposure")
        case "whiteBalance": return L10n.tr("clipboard.whiteBalance")
        case "filmEffects": return L10n.tr("clipboard.filmEffects")
        case "printEffects": return L10n.tr("clipboard.printEffects")
        case "scenePlacement": return L10n.tr("clipboard.scenePlacement")
        case "masks": return L10n.tr("clipboard.masks")
        }
        return id
    }
    function groupHelp(id) {
        switch (id) {
        case "filmAndPaper": return L10n.tr("clipboard.filmAndPaperHelp")
        case "exposure": return L10n.tr("clipboard.exposureHelp")
        case "whiteBalance": return L10n.tr("clipboard.whiteBalanceHelp")
        case "filmEffects": return L10n.tr("clipboard.filmEffectsHelp")
        case "printEffects": return L10n.tr("clipboard.printEffectsHelp")
        case "scenePlacement": return L10n.tr("clipboard.scenePlacementHelp")
        case "masks": return L10n.tr("clipboard.masksHelp")
        }
        return ""
    }

    Repeater {
        model: preview.clipboardGroups
        delegate: CheckRow {
            required property var modelData
            objectName: "clipboardGroup_" + modelData.id
            label: section.groupTitle(modelData.id)
            checked: modelData.ticked === true
            toolTip: section.groupHelp(modelData.id)
            onToggledTo: function(on) { preview.setClipboardGroup(modelData.id, on) }
        }
    }
    // What is held: the source's file name and how many of the seven groups.
    Note {
        objectName: "clipboardHolds"
        text: section.clip.holds === true
            ? L10n.tr("clipboard.holds", [section.clip.source, section.clip.groupCount])
            : L10n.tr("clipboard.empty")
    }
    RowLayout {
        spacing: 8
        PillButton {
            objectName: "clipboardCopy"
            text: L10n.tr("clipboard.copy")
            available: section.editor.canCopySettings
            toolTip: L10n.tr("clipboard.copyHelp")
            reason: preview.hasFrame ? L10n.tr("clipboard.copyReason") : L10n.tr("clipboard.noPhoto")
            onClicked: preview.copySettings()
        }
        PillButton {
            objectName: "clipboardPaste"
            text: section.clip.pasteTargets > 1 ? L10n.tr("clipboard.pasteTo", [section.clip.pasteTargets]) : L10n.tr("clipboard.paste")
            available: section.editor.canPasteSettings
            toolTip: L10n.tr("clipboard.pasteHelp")
            reason: section.lockedReason.length > 0 ? section.lockedReason
                  : section.clip.holds === true ? L10n.tr("clipboard.noPhoto") : L10n.tr("clipboard.empty")
            onClicked: preview.pasteSettings()
        }
        Item { Layout.fillWidth: true }
    }
    RowLayout {
        PillButton {
            objectName: "clipboardSync"
            text: section.clip.syncTargets > 0 ? L10n.tr("clipboard.syncTo", [section.clip.syncTargets]) : L10n.tr("clipboard.sync")
            available: section.editor.canSync
            toolTip: L10n.tr("clipboard.syncHelp")
            reason: section.lockedReason.length > 0 ? section.lockedReason : L10n.tr("clipboard.syncReason")
            onClicked: preview.syncSelectedSettings(false)
        }
        Item { Layout.fillWidth: true }
    }
}
