pragma Singleton
import QtQuick
import SpektraLab.Native 1.0

// Which rail sections are open, by section id.
//
// The Mac persists the same thing per key (`PanelSection`'s @AppStorage,
// Session.uiKey + "section.<key>"); here it is the preferences file's
// "layout.section.<id>" (AppSettings.hpp). A test or scripted run keeps that
// file in its own directory, so no run inherits a state another left behind
// (the Mac's trap 24), and Settings > Reset All Layout clears it (reset()).
// `revision` is read by expanded() so every header bound to it re-evaluates
// when any section changes.
QtObject {
    property int revision: 0
    property var store: ({})

    function expanded(id, fallback) {
        revision
        if (store[id] !== undefined) return store[id]
        var saved = AppSettings.value("layout.section." + id)
        return saved === undefined ? fallback : saved === true
    }
    function setExpanded(id, value) {
        if (store[id] === value) return
        store[id] = value
        AppSettings.setValue("layout.section." + id, value)
        revision++
    }
    // Every section back to its declared default; the caller clears the keys.
    function reset() {
        store = {}
        revision++
    }
}
