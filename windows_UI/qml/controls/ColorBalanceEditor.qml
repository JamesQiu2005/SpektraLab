import QtQuick
import QtQuick.Layouts

// Capture One's Color Balance (ColorWheel.swift ColorBalanceEditor): five
// tabs -- Master, 3-Way, Shadow, Midtone, Highlight -- one large wheel for a
// single zone, or the 3-Way triangle (midtone above, shadow and highlight
// below with their labels above them). Sizes are ColorBalanceLayout's,
// functions of the width the section gives: single = 0.55 of it less the
// ring, the triangle 0.40 and 0.30, each clamped as the Mac clamps them.
ColumnLayout {
    id: editor
    property string tab: "master"
    readonly property var tabs: ["master", "threeWay", "shadows", "midtones", "highlights"]
    spacing: 8
    Layout.fillWidth: true

    function title(t) {
        return t === "master" ? L10n.tr("postDev.balance.master") : t === "threeWay" ? L10n.tr("postDev.balance.threeWay")
            : t === "shadows" ? L10n.tr("postDev.balance.shadow") : t === "midtones" ? L10n.tr("postDev.balance.midtone")
            : L10n.tr("postDev.balance.highlight")
    }
    function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
    function arcBand(w) { return clamp(w * 0.09, 4.5, 10) + clamp(w * 0.05, 3, 5) + 1 }
    readonly property real room: Math.max(width, 1)
    readonly property real single: {
        var raw = clamp(room * 0.55, 64, 150)
        return clamp(raw - 2 * arcBand(raw), 64, 150)
    }
    readonly property real midtone: clamp(room * 0.40, 64, 120)
    readonly property real side: clamp(room * 0.30, 44, 96)

    RowLayout {
        Layout.fillWidth: true
        spacing: 0
        Repeater {
            model: editor.tabs
            delegate: Item {
                required property string modelData
                readonly property bool on: modelData === editor.tab
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                implicitHeight: 20
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.min(implicitWidth, parent.width)
                    y: 1
                    text: editor.title(parent.modelData)
                    fontSizeMode: Text.HorizontalFit
                    minimumPixelSize: Theme.fontSmall - 2
                    horizontalAlignment: Text.AlignHCenter
                    color: parent.on ? Theme.accent : Theme.secondaryText
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
                }
                Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width - 6; height: 1.5
                    color: parent.on ? Theme.accent : "transparent"
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: editor.tab = parent.modelData
                }
            }
        }
    }
    ZoneWheel {
        Layout.alignment: Qt.AlignHCenter; Layout.fillWidth: false
        visible: editor.tab !== "threeWay"
        zone: editor.tab === "threeWay" ? "midtones" : editor.tab
        wheel: editor.single
    }
    ColumnLayout {
        visible: editor.tab === "threeWay"
        Layout.fillWidth: true
        spacing: 6
        ZoneWheel { zone: "midtones"; wheel: editor.midtone; label: L10n.tr("postDev.balance.midtone"); Layout.alignment: Qt.AlignHCenter; Layout.fillWidth: false }
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: Math.max(6, editor.room * 0.03)
            ZoneWheel { zone: "shadows"; wheel: editor.side; label: L10n.tr("postDev.balance.shadow"); labelFirst: true; Layout.fillWidth: false }
            ZoneWheel { zone: "highlights"; wheel: editor.side; label: L10n.tr("postDev.balance.highlight"); labelFirst: true; Layout.fillWidth: false }
        }
    }
}
