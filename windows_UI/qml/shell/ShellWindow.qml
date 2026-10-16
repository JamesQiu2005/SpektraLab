import QtQuick
import QtQuick.Controls

// A secondary window of the shell -- Settings, About, a licence text -- in the
// editor's palette (Main.qml): the rail colour, the Mac's three inks, Segoe
// UI. Declared inside the editor window, so Qt makes it transient for it: it
// stays above the editor, and closing the editor still quits the app (a
// transient window does not keep QGuiApplication running).
//
//   present()   show, raise and focus -- what a menu command calls
//   Esc closes, as a Windows dialog does.
ApplicationWindow {
    id: shell
    visible: false
    flags: Qt.Dialog
    color: Theme.card
    font.family: Theme.fontFamily
    font.pixelSize: Theme.fontLabel
    palette.window: Theme.card
    palette.windowText: Theme.text
    palette.text: Theme.text
    palette.buttonText: Theme.text
    palette.base: Theme.well
    palette.button: Theme.well
    palette.highlight: Theme.accent
    palette.highlightedText: Theme.selectionInk
    palette.toolTipBase: "#1f1f1e"
    palette.toolTipText: Theme.text
    palette.dark: Theme.ruleRegion
    palette.mid: Theme.rule

    function present() {
        shell.show()
        shell.raise()
        shell.requestActivate()
    }
    Shortcut { sequence: "Escape"; onActivated: shell.close() }
}
