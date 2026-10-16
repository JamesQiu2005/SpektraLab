import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Print (PrintProfileSection.swift): the papers grouped Still / Cine, then
// Digital (the Digital Intermediate, greyed until the canvas has a Cineon
// view) and Positive with "No Print Profile"; under them Print Effects and
// Extended Dynamic Range, the print stage's two switches.
//
// Every row comes from the controller's paperCatalog with the Mac's rules: a
// slide film greys every paper (it is scanned directly, and "No Print
// Profile" is the chosen row while the paper is remembered for the next
// negative); a black-and-white film greys the colour papers and a colour film
// the silver one, each with its reason on hover. "No Print Profile" is
// offered for any film: it scans the developed film and keeps the paper, so
// choosing a paper again prints on it.
//
// Print Effects (glare and pre-flash, their settings kept) means nothing
// without a print, so it greys with No Print Profile. EDR keeps its row but
// is unavailable: the Windows canvas and files are SDR.
MacSection {
    id: section
    sectionId: "print"
    title: L10n.tr("print.title")
    inset: false
    readonly property bool printEffects: preview.parameters.print_effects === undefined ? true : preview.parameters.print_effects === true
    menuItems: [
        // PrintProfileSection.swift:198-207: the film's declared paper, printed;
        // disabled for a slide, which declares none.
        RailMenuItem {
            text: L10n.tr("print.useFilmPaper")
            enabled: preview.settingsEditable && preview.canUseFilmPaper
            onTriggered: preview.useFilmPaper()
        },
        RailMenuItem { text: L10n.tr("print.processFrame"); enabled: false },
        MenuSeparator {},
        // The Mac disables it while no paper has a baked LUT; Windows bakes none.
        RailMenuItem { text: L10n.tr("print.fastFlip"); enabled: false }
    ]

    StockList {
        listObjectName: "paperList"
        // Every paper, the Digital row and "No Print Profile" without scrolling.
        visibleRows: 16
        rows: Catalog.paperRows(preview.paperCatalog)
        currentKey: preview.printSelection
        editable: preview.settingsEditable
        onPicked: function(key) { if (key !== Catalog.digitalKey) preview.selectPaper(key) }
    }
    ColumnLayout {
        Layout.fillWidth: true
        Layout.leftMargin: Theme.rowInset; Layout.rightMargin: Theme.rowInset
        Layout.topMargin: Theme.rowSpacing + 5
        spacing: Theme.rowSpacing
        CheckRow {
            objectName: "printEffectsRow"
            label: L10n.tr("print.effects")
            checked: section.printEffects
            available: preview.settingsEditable && !preview.noPrintProfile
            reason: preview.noPrintProfile ? L10n.tr("print.reason.effectsScanFilm") : ""
            toolTip: L10n.tr("print.effectsHelp")
            onToggledTo: function(on) { preview.setParameter("print_effects", on) }
        }
        CheckRow {
            label: L10n.tr("print.edr")
            sublabel: L10n.tr("print.edrScope")
            checked: false
            available: false
            reason: L10n.tr("print.reason.edrWindows")
        }
    }
}
