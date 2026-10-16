pragma Singleton
import QtQuick

// Every visual token of the editor, ported from the macOS app's
// modern_UI/Spektrafilm/Spektrafilm/Theme/Theme.swift (the "v3/v4" drawing).
// Colours are the Mac's sRGB values exactly: they are display-independent and
// Qt draws them through the same pipeline as the canvas surround, so the
// letterbox and the window grey cannot disagree (AGENTS.md trap 27).
//
// Sizes are the Mac's metrics in logical pixels where they describe layout
// (rows, insets, rail widths). Type is mapped onto Segoe UI rather than
// copied: the Mac sets SF Pro Bold at 9-12 pt times a 1.15 interface scale,
// and Segoe UI Semibold at the integer pixel sizes below reads at the same
// density on Windows. Hierarchy comes from ink (text / secondaryText / dim),
// as on the Mac, more than from size.
//
// The names after "kept for files not yet ported" are the first Qt theme's;
// they now point at the Mac tokens so a pane written against them still draws
// in the new palette.
QtObject {
    id: theme

    // --- colours (Theme.swift) ---
    // The canvas surround, and every well, pill and slider track: one grey,
    // four jobs (the drawing's .st13).
    readonly property color ground: "#5f5f5f"
    // The rails, the tool bar and the filmstrip (.st15).
    readonly property color card: "#2d2d2c"
    readonly property color well: ground
    readonly property color pill: ground
    // Hairlines: `rule` between sections inside a rail, `ruleRegion` the darker
    // groove between the window's regions (rail | canvas, bar | canvas, ...).
    readonly property color rule: "#3a3b39"
    readonly property color ruleRegion: "#1a1a19"
    // Three inks: what is said, what is asked, metadata.
    readonly property color text: "#f9f7f3"
    readonly property color secondaryText: "#dad8d4"
    readonly property color dim: "#898989"
    // Plot grounds (histogram, curves, the Pre-Dev / Post-Dev track).
    readonly property color plot: "#1e1f1e"
    readonly property color plotGrid: "#3a3b39"
    readonly property color plotMidGrey: "#4a4b49"
    // The one accent: actions, state, "on".
    readonly property color accent: "#e1a95f"
    // A chosen stock row: a white capsule with near-black text.
    readonly property color selection: "#ffffff"
    readonly property color selectionInk: "#0f0e0e"
    // The filmstrip's frame round the open photo (and, weaker, the picked set).
    readonly property color selectionFrame: "#faf8f4"
    readonly property color knob: "#fbf8f3"
    readonly property color navigatorWell: "#1a1a19"
    readonly property color histR: "#e8524e"
    readonly property color histG: "#62c462"
    readonly property color histB: "#5d7de8"
    readonly property color histY: "#bdbdbd"
    readonly property color latitudeInside: "#9c9c9a"
    readonly property color latitudeInsideEdge: "#d6d5d2"
    readonly property color latitudeBeyond: "#3f3f3d"
    // Windows-only: failures and persistence warnings, which the Mac shows in
    // system alerts rather than on a rail.
    readonly property color warning: "#ffb39f"
    // Hover plate behind an icon or row on Windows, where a pointer target
    // without any hover response reads as dead.
    readonly property color hover: "#14ffffff"
    // "If one option is non-selectable, both the text and the input pill is
    // greyed across the app" -- one opacity applied to the whole row.
    readonly property real disabledOpacity: 0.38

    // --- type ---
    // Segoe UI ships with every Windows and has real Semibold/Bold faces,
    // which a variable face does not give the offscreen (file-database)
    // platform the self-test runs on.
    readonly property string fontFamily: "Segoe UI"
    // System icon fonts, never bundled: Segoe Fluent Icons (Windows 11), else
    // Segoe MDL2 Assets (Windows 10), whose code points the glyphs in
    // Icons.qml share. Asked of the font matcher for the one family rather
    // than through Qt.fontFamilies(), which enumerates every installed face
    // and logs DirectWrite failures for legacy bitmap fonts (Fixedsys) at
    // fractional scale factors.
    readonly property Text iconProbe: Text { font.family: "Segoe Fluent Icons"; text: "\uE90C" }
    readonly property string iconFamily: iconProbe.fontInfo.family === "Segoe Fluent Icons"
        ? "Segoe Fluent Icons" : "Segoe MDL2 Assets"
    readonly property int fontRail: 14       // a rail's own name
    readonly property int fontTitle: 13      // a section title
    readonly property int fontLabel: 12      // a control's label (Mac `body`)
    readonly property int fontSmall: 11      // values, stock rows, pills (Mac `small`)
    readonly property int fontMeta: 10       // sub-labels, captions (Mac `meta`)
    readonly property int fontAction: 14     // Process / Original
    readonly property int fontCine: 7        // the CINE badge
    // The Mac sets every role in SF Pro Bold and lets ink carry the
    // hierarchy. Segoe UI Bold is heavier than SF Pro Bold at these sizes, so
    // titles take Bold and everything else Semibold, which reads at the same
    // weight beside a Mac capture.
    readonly property int weightTitle: Font.Bold
    readonly property int weightText: Font.DemiBold

    // --- metrics (Theme.swift Metric, in logical px) ---
    // The rail headers and the tool bar share one 38 px top row.
    readonly property int headerBarHeight: 38
    // A section: 26 px header row, content, 10 px of air, hairline.
    readonly property int sectionHeaderHeight: 26
    readonly property int sectionBottom: 10
    readonly property int headerLeading: 7
    readonly property int headerTitleGap: 5
    readonly property int headerTrailing: 6
    // A control row: inset 16 from both rail edges, a 22 px line box, rows 5
    // apart, an optional 15 px second line under the label.
    readonly property int rowInset: 16
    readonly property int rowHeight: 22
    readonly property int subRowHeight: 15
    readonly property int rowSpacing: 5
    // Every pill, field and value box.
    readonly property int controlHeight: 18
    readonly property real fieldRadius: 4.25
    // The label column: the left rail's (Mac sliderLabelWidth 84) and the
    // Parameters rail's one grid (96 pt at the 115 % interface scale).
    readonly property int labelWidth: 84
    readonly property int parameterLabelWidth: 110
    // The slider's value pill and the gap before it; a picker that does not
    // fill its row.
    readonly property int valueWidth: 46
    readonly property int valueGap: 12
    readonly property int pickerWidth: 108
    // Slider ink. The Mac's 1.36 x 6.13 pt are Retina points; at one device
    // pixel a 2 px track and an 8 x 7 knob are the same marks made visible.
    readonly property int trackHeight: 2
    readonly property int knobWidth: 8
    readonly property int knobHeight: 7
    readonly property int checkSize: 10
    readonly property int hitTarget: 22
    readonly property int toggleRowHeight: 22
    // The film and print lists: an 19 px pitch, a 16 px white capsule inset
    // asymmetrically (the trailing side leaves room for the CINE badge and
    // the scroll indicator).
    readonly property int listRowHeight: 19
    readonly property int stockSelectionHeight: 16
    readonly property int stockLeadingInset: 12
    readonly property int stockTrailingInset: 20
    readonly property int stockTextInset: 18
    readonly property int cinePillWidth: 22
    readonly property int cinePillHeight: 9
    // Navigator well, plots.
    readonly property int navigatorHeight: 183
    readonly property int navigatorInset: 12
    readonly property int plotHeight: 60
    readonly property int maskPlotHeight: 44
    // Tool bar.
    readonly property int toolButton: 28
    readonly property int toolGlyph: 16
    readonly property int barPadding: 16
    readonly property int barIconGap: 2
    readonly property int barClusterGap: 20
    readonly property int barActionLeading: 40
    readonly property int actionGap: 12
    readonly property int zoomGap: 16
    readonly property int actionHeight: 20
    readonly property real actionRadius: 9.26
    readonly property int zoomPillWidth: 46
    readonly property int zoomPillHeight: 21
    // Filmstrip.
    readonly property int filmstripHeight: 132
    readonly property int thumbHeight: 104
    readonly property int stripSpacing: 14
    // Rails: the standard width is a little wider than the Mac's 254 / 288,
    // because Segoe UI sets the same labels slightly wider than SF Pro; the
    // bounds are the Mac's own widened to match. A drag on the rail's inner
    // edge moves it inside the range; a double-click returns to standard.
    readonly property int leftRailNarrowest: 232
    readonly property int leftRailStandard: 290
    readonly property int leftRailWidest: 420
    readonly property int rightRailNarrowest: 280
    readonly property int rightRailStandard: 320
    readonly property int rightRailWidest: 440
    readonly property int resizeHandleWidth: 6
    readonly property int minWindowWidth: 1100
    readonly property int minWindowHeight: 700

    // --- kept for files not yet ported (the first Qt theme's names) ---
    readonly property color muted: dim
    readonly property color line: rule
    readonly property color wellDark: navigatorWell
    readonly property color selectionText: selectionInk
    readonly property int leftWidth: leftRailStandard
    readonly property int rightWidth: rightRailStandard
    readonly property int topHeight: headerBarHeight
    readonly property int stripHeight: filmstripHeight
}
