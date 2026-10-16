pragma Singleton
import QtQuick

// Which rail sections are open, by section id, for this run of the app.
//
// The Mac persists the same thing per key (`PanelSection`'s @AppStorage);
// here it lives in memory only, so a restart is the drawing's defaults again
// and no test can inherit a state another run left behind (the Mac's trap 24).
// `revision` is read by expanded() so every header bound to it re-evaluates
// when any section changes.
QtObject {
    property int revision: 0
    property var store: ({})

    function expanded(id, fallback) {
        revision
        return store[id] === undefined ? fallback : store[id]
    }
    function setExpanded(id, value) {
        if (store[id] === value) return
        store[id] = value
        revision++
    }
}
