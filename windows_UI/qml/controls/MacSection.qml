import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A rail section, as the Mac draws one (SectionHeader.swift / PanelSection):
// a 26 px header -- disclosure triangle, bold title, an optional caption at
// the right, an optional reset arrow and "..." menu -- then the content, 10 px
// of air and a hairline. A folded section is its header and nothing else.
//
//   sectionId          key for the open/folded state (SectionStates, in memory)
//   title              the header's title
//   defaultExpanded    the state before the user has touched it
//   caption            dim metadata at the header's trailing end (Latitude's
//                      "film · paper"); elided, never wraps
//   foldedCaption      the caption shown only while folded
//   resetVisible, resetAvailable, resetToolTip, resetReason, resetRequested()
//                      the reset arrow. The Mac requires its tooltip to say in
//                      words what it resets; so does this.
//   menuItems          RailMenuItem / MenuSeparator children of the "..." menu;
//                      no items, no "..." (the Mac draws none either)
//   headerCheckVisible, headerChecked, headerCheckAvailable, headerCheckReason,
//   headerToggled(bool)  the section's own switch at the header's end (Film
//                      Edge, Date Back), for a thing the frame has or has not
//   inset              content inset 16 px from both rail edges (rows); false
//                      for full-width content (stock lists, the navigator)
//   divider            the hairline under the section; off for the last one
//   content            (default) the rows, a ColumnLayout 5 px apart
ColumnLayout {
    id: section
    property string sectionId
    property string title
    property bool defaultExpanded: true
    property string caption
    property string foldedCaption
    property bool resetVisible: false
    property bool resetAvailable: true
    property string resetToolTip
    property string resetReason
    property alias menuItems: sectionMenu.contentData
    property bool headerCheckVisible: false
    property bool headerChecked: false
    property bool headerCheckAvailable: true
    property string headerCheckReason
    property string headerCheckToolTip
    property bool inset: true
    property bool divider: true
    default property alias content: body.data
    readonly property bool expanded: SectionStates.expanded(sectionId, defaultExpanded)
    signal resetRequested()
    signal headerToggled(bool on)

    function setExpanded(open) { SectionStates.setExpanded(sectionId, open) }

    Layout.fillWidth: true
    spacing: 0

    Item {
        id: header
        Layout.fillWidth: true
        Layout.preferredHeight: Theme.sectionHeaderHeight
        // The whole header row folds and unfolds, not only the triangle: on
        // Windows a row that highlights nothing and ignores clicks reads as
        // static text.
        TapHandler { onTapped: section.setExpanded(!section.expanded) }
        HoverHandler { id: headerHover; cursorShape: Qt.PointingHandCursor }
        Triangle {
            id: disclosure
            x: Theme.headerLeading + 3; anchors.verticalCenter: parent.verticalCenter
            width: 11; height: 6.5
            rotation: section.expanded ? 0 : -90
            color: Theme.text
        }
        Text {
            id: titleText
            x: disclosure.x + disclosure.width + 3 + Theme.headerTitleGap
            anchors.verticalCenter: parent.verticalCenter
            text: section.title
            color: Theme.text
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontTitle; font.weight: Theme.weightTitle
        }
        Row {
            id: trailing
            anchors.right: parent.right; anchors.rightMargin: Theme.headerTrailing
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0
            SquareCheck {
                anchors.verticalCenter: parent.verticalCenter
                visible: section.headerCheckVisible
                checked: section.headerChecked
                available: section.headerCheckAvailable
                reason: section.headerCheckReason
                toolTip: section.headerCheckToolTip
                onToggledTo: function(on) { section.headerToggled(on) }
            }
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                visible: section.resetVisible
                size: 24; glyphSize: 10
                glyph: Icons.reset
                available: section.resetAvailable
                toolTip: section.resetToolTip
                reason: section.resetReason.length > 0 ? section.resetReason : section.resetToolTip
                onClicked: section.resetRequested()
            }
            IconButton {
                id: moreButton
                anchors.verticalCenter: parent.verticalCenter
                visible: sectionMenu.count > 0
                size: 24; glyphSize: 12
                glyph: Icons.more
                onClicked: sectionMenu.popup(moreButton, 0, moreButton.height)
            }
        }
        Text {
            anchors.left: titleText.right; anchors.leftMargin: 8
            anchors.right: trailing.left; anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            text: section.caption.length > 0 ? section.caption : section.expanded ? "" : section.foldedCaption
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
            color: Theme.dim
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
        }
    }
    RailMenu { id: sectionMenu }
    ColumnLayout {
        id: body
        visible: section.expanded
        Layout.fillWidth: true
        Layout.leftMargin: section.inset ? Theme.rowInset : 0
        Layout.rightMargin: section.inset ? Theme.rowInset : 0
        Layout.bottomMargin: Theme.sectionBottom
        spacing: Theme.rowSpacing
    }
    Rectangle {
        visible: section.divider
        Layout.fillWidth: true
        Layout.preferredHeight: 1
        color: Theme.rule
    }
}
