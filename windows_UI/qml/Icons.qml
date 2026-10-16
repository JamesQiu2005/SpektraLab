pragma Singleton
import QtQuick

// Glyphs of the Windows system icon font (Theme.iconFamily: Segoe Fluent
// Icons, else Segoe MDL2 Assets). Nothing is bundled or downloaded; each code
// point below was chosen by rendering it and comparing it with the SF Symbol
// the macOS app draws in the same place (named after the //).
//
// Every one is present in both fonts (checked against SegoeIcons.ttf and
// segmdl2.ttf): a code point a font lacks sends Qt through its whole
// fallback list, which costs time and logs DirectWrite failures.
//
// Written as escapes, never as literal private-use characters, so the files
// stay plain text for every editor and for the localizer test's scan.
QtObject {
    readonly property string sidebarLeft: "\uE90C"     // sidebar.left (DockLeft)
    readonly property string sidebarRight: "\uE90D"    // sidebar.right (DockRight)
    readonly property string importFile: "\uE896"      // square.and.arrow.down
    readonly property string exportFile: "\uE898"      // square.and.arrow.up
    readonly property string pointer: "\uE8B0"         // cursorarrow
    readonly property string crop: "\uE7A8"            // crop
    readonly property string undo: "\uE7A7"
    readonly property string redo: "\uE7A6"
    readonly property string zoomIn: "\uE8A3"          // plus.magnifyingglass
    readonly property string zoomOut: "\uE71F"         // minus.magnifyingglass
    readonly property string rotate: "\uE7AD"          // rotate.right; mirrored for rotate.left
    readonly property string flip: "\uE8AB"            // flip; turned 90 degrees for vertical
    readonly property string reset: "\uE777"           // arrow.counterclockwise
    readonly property string more: "\uE712"            // the section header's "..."
    readonly property string chevronLeft: "\uE76B"
    readonly property string chevronRight: "\uE76C"
    readonly property string chevronDown: "\uE70D"
    readonly property string chevronUp: "\uE70E"
    readonly property string check: "\uE73E"
    readonly property string photo: "\uE91B"
    readonly property string warning: "\uE7BA"
}
