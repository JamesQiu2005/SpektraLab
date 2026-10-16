import QtQuick
import QtQuick.Controls

// A rail's scroll indicator: a 3 px thumb in the metadata ink, over the
// content rather than beside it (the Mac hides the rails' indicators; a thin
// overlay keeps "there is more below" visible on Windows without taking the
// rows' width). Shown only while the content is taller than the rail.
ScrollBar {
    id: bar
    width: 8
    padding: 2
    policy: size < 1 ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
    contentItem: Rectangle {
        implicitWidth: 3
        radius: 1.5
        color: Theme.dim
        opacity: bar.pressed ? 1 : bar.active ? 0.8 : 0.35
    }
}
