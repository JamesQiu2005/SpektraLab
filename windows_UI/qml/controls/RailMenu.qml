import QtQuick
import QtQuick.Controls

// The dark pop-up menu every "..." and the zoom pill open: a rounded card in
// the rail colour with a hairline edge. Items are RailMenuItem (and
// MenuSeparator, which takes the rule colour from the palette set here).
// Windows-native in behaviour -- keyboard navigation, Esc, click-away -- and
// the Mac's in ink.
Menu {
    id: menu
    padding: 4
    palette.window: Theme.card
    palette.windowText: Theme.text
    palette.mid: Theme.rule
    palette.dark: Theme.rule
    // As wide as its widest item, at least 180: a reset item spells out what
    // it resets, and the style's own width would elide it.
    implicitWidth: {
        var w = 180
        for (var i = 0; i < count; ++i) {
            var it = itemAt(i)
            if (it) w = Math.max(w, it.implicitWidth + leftPadding + rightPadding)
        }
        return w
    }
    background: Rectangle {
        implicitWidth: 180
        color: "#262625"
        border.color: Theme.ruleRegion
        radius: 6
    }
    delegate: RailMenuItem {}
}
