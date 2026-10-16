import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// RAW Decode: the validated compatible decode, or the experimental one that
// keeps highlight headroom. A change re-opens the photo.
Section {
    title: L10n.tr("decode.title")
    ComboBox {
        id: decode; Layout.fillWidth: true
        model: [L10n.tr("decode.compatible"), L10n.tr("decode.headroom")]
        // Reads `model` so a language switch re-runs the binding (see FilmFormatSection).
        currentIndex: { model; return preview.decodeMode }
        enabled: preview.settingsEditable; onActivated: preview.decodeMode = currentIndex
    }
    Note { text: preview.decodeMode ? L10n.tr("decode.headroomNote") : L10n.tr("decode.compatibleNote") }
}
