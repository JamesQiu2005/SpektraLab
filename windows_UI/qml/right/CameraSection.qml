import QtQuick

// Input / Camera: the scene's exposure onto the film.
Section {
    title: L10n.tr("camera.title")
    Adjustment { label: L10n.tr("camera.filmExposure"); setting: "filmExposureEv"; from: -4; to: 4; step: 0.1; decimals: 1; suffix: " EV" }
    Note { text: L10n.tr("camera.filmExposureNote") }
}
