import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Print (PrintProfileSection.swift): the papers grouped Still / Cine, then
// Digital (the Digital Intermediate, greyed until the engine boundary offers
// it) and Positive with "No Print Profile"; under them Print Effects and Extended
// Dynamic Range, the print stage's two switches.
//
// A slide film is scanned directly (the controller's rule, as on the Mac):
// while one is chosen the papers grey with the reason, "No Print Profile" is
// the chosen row, and the paper itself is remembered for the next negative.
// Print Effects and EDR are print parameters the Windows settings table does
// not carry yet; they keep their rows, greyed with the reason, and the "..."
// lists the Mac's paper actions the same way.
MacSection {
    id: section
    sectionId: "print"
    title: L10n.tr("print.title")
    inset: false
    menuItems: [
        RailMenuItem { text: L10n.tr("print.useFilmPaper"); enabled: false },
        RailMenuItem { text: L10n.tr("print.processFrame"); enabled: false },
        MenuSeparator {},
        RailMenuItem { text: L10n.tr("print.fastFlip"); checkable: true; enabled: false }
    ]

    StockList {
        listObjectName: "paperList"
        // Every paper, the Digital row and "No Print Profile" without scrolling.
        visibleRows: 15
        rows: Catalog.paperRows(preview.papers, preview.filmIsPositive)
        currentKey: preview.filmIsPositive ? Catalog.noPrintKey : preview.paperIndex
        editable: preview.settingsEditable
        onPicked: function(key) { if (key >= 0) preview.paperIndex = key }
    }
    ColumnLayout {
        Layout.fillWidth: true
        Layout.leftMargin: Theme.rowInset; Layout.rightMargin: Theme.rowInset
        Layout.topMargin: Theme.rowSpacing
        spacing: Theme.rowSpacing
        CheckRow {
            label: L10n.tr("print.effects")
            checked: true
            available: false
            reason: L10n.tr("placeholder.printEffects")
        }
        CheckRow {
            label: L10n.tr("print.edr")
            sublabel: L10n.tr("print.edrScope")
            checked: false
            available: false
            reason: L10n.tr("placeholder.edr")
        }
    }
}
