pragma Singleton
import QtQuick
QtObject {
    // Ported from upstream Theme.swift at 61bfc49, not operating-system defaults.
    readonly property color ground: "#5f5f5f"
    readonly property color card: "#2d2d2c"
    readonly property color text: "#faf8f4"
    readonly property color muted: "#b7b6b3"
    readonly property color accent: "#e1a95f"
    readonly property color line: "#858582"
    readonly property color well: "#484846"
    readonly property color wellDark: "#1e1e1c"
    readonly property color selection: "#f1f0eb"
    readonly property color selectionText: "#252523"
    readonly property int leftWidth: 246
    readonly property int rightWidth: 288
    readonly property int topHeight: 38
    readonly property int stripHeight: 160
}
