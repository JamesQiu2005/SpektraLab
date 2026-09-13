//  Theme.swift — every visual token in the interface, measured from the design.
//
//  The drawing (`modern_UI/reference_layout/SVG_link/sample_frontend.svg`) is
//  a 3840×2160 canvas, i.e. a 1920×1080 window at 2×. Every number here is
//  the drawing's value divided by two. Nothing in a view file may carry a
//  literal colour or size that could have come from here — that is the rule
//  that keeps the interface matching the drawing when one token moves.

import SwiftUI

enum Theme {

    // MARK: colours (from the SVG's style classes)

    /// `.st2` — the window ground. The canvas surround and every well.
    static let ground = Color(hex: 0x5F5F5F)
    /// `.st5` — the four floating cards (panels, top bar, filmstrip).
    static let card = Color(hex: 0x2C2D2B)
    /// Wells inside a card: same value as the ground, on purpose — the design
    /// reads as "cards punched through to the ground".
    static let well = ground
    /// A pill or field sitting inside a well (the Format picker, the zoom pill).
    static let field = card
    /// `.st4` / `.st9` — primary text and glyphs.
    static let text = Color(hex: 0xFAF8F4)
    /// `.st6` — slider tracks, dim captions.
    static let dim = Color(hex: 0x898989)
    /// Text on a well that is secondary (group headers "Still" / "Cine").
    static let secondaryText = Color(hex: 0xDAD8D4)
    /// Plot grounds (histogram / curve) are one step darker than the card.
    static let plot = Color(hex: 0x1E1F1E)
    static let plotGrid = Color(hex: 0x3A3B39)
    /// The one accent in the interface: the active curve tab and its points.
    static let accent = Color(hex: 0xEE8A2B)
    /// The export page's accent, `.cls-12` in
    /// `reference_layout/Export_Page/export_page.svg`: the chosen mode in the
    /// bar's toggle. **The user's own drawing says `#f08724`**, and this page
    /// follows its drawing: the two oranges are 2, 3 and 7 counts apart a
    /// channel (240/135/36 against 238/138/43), which is nothing on screen but
    /// is not the same number, and the file that names the colour wins.
    static let exportAccent = Color(hex: 0xF08724)
    /// `.cls-21` — the naming chips' plate and, in the drawing, the unchosen
    /// filmstrip cell's frame. A well-side grey one step up from `ground`.
    static let exportChip = Color(hex: 0x686969)
    static let selectionFrame = Color(hex: 0xFAF8F4)
    static let knob = Color(hex: 0xFAF8F4)
    static let canvasSurround = ground

    static let histR = Color(hex: 0xE8524E)
    static let histG = Color(hex: 0x62C462)
    static let histB = Color(hex: 0x5D7DE8)
    static let histY = Color(hex: 0xBDBDBD)

    // MARK: metrics (SVG ÷ 2)

    enum Metric {
        /// Card corner radius (rx 30 → 15).
        static let cardRadius: CGFloat = 15
        /// Well corner radius (rx 22.9 → 11.5).
        static let wellRadius: CGFloat = 11.5
        /// Outer margin between window edge and cards (17.9 → 9, 14.1 → 7).
        static let outerX: CGFloat = 9
        static let outerY: CGFloat = 7
        /// Gutter between a side panel and the centre column. The drawing's is
        /// 8 (690.5 − 674.8); 6 spends less screen on ground between the four
        /// cards. Deliberate departure from the drawing.
        static let gutter: CGFloat = 6
        static let leftPanelWidth: CGFloat = 328
        static let rightPanelWidth: CGFloat = 286
        static let topBarHeight: CGFloat = 41
        static let filmstripHeight: CGFloat = 125
        /// Well inset from the card edge (36.2 − 17.9 → 9).
        static let wellInset: CGFloat = 9
        /// Height of the left panel's header row.
        static let panelHeaderHeight: CGFloat = 44
        /// Centre of the **top bar** in *window* coordinates, from the top —
        /// where the traffic lights go. The bar is the first row of the
        /// window, it is full width and it never collapses, so it is the one
        /// row in the interface that always has a home for the buttons
        /// (`Windows/TrafficLights.swift`). It used to be the left panel's
        /// header, which is a row that disappears when the panel folds.
        static var trafficLightCentreY: CGFloat { outerY + topBarHeight / 2 }
        /// Leading edge of the close button, in window coordinates. The bar
        /// starts at `outerX` and every card insets its content by 12, so the
        /// buttons take that inset rather than a special one — which is what
        /// makes the corner read as one row instead of two things that
        /// happen to be near each other.
        static var trafficLightLeading: CGFloat { outerX + 12 }
        /// Gap between the zoom button and the first glyph after it. Xcode's
        /// is about this; below ~12 the glyph reads as a fourth window button.
        static let trafficLightToGlyph: CGFloat = 16
        /// Leading inset for a side panel's header row, measured from the
        /// card's own leading edge — the drawing's own 12, which is what every
        /// other card keeps. The right panel's header glyph takes it; the left
        /// panel's header has no leading control at all any more (import and
        /// export moved to the top bar), so its row is now purely the drag
        /// surface and the card menu.
        ///
        /// This was a derived number until the window buttons moved onto the
        /// top bar: it existed only to push the import glyph clear of them.
        /// With the buttons on a row of their own, a header is an ordinary
        /// card header again and nothing here has to know they exist.
        static let panelHeaderLeading: CGFloat = 12
        /// Leading inset for the top bar's first control, from the bar's own
        /// leading edge — the derivation `panelHeaderLeading` used to carry,
        /// moved to the row the buttons are on now.
        ///
        /// `.windowStyle(.hiddenTitleBar)` does not remove the three window
        /// buttons; it floats them over the content. They are placed rather
        /// than avoided, so this follows from where they are: the row ends at
        /// `trafficLightLeading + rowWidth`, the glyph starts
        /// `trafficLightToGlyph` after that, and the glyph is centred in a
        /// 28 pt box (`TopBar.toolButton`). The drawing puts the tools further
        /// right than this; the drawing is a sketch and the derivation is what
        /// keeps the corner from reading as two unrelated rows. The window
        /// server draws the buttons, so no offscreen capture
        /// (`Tools/snapshot.sh`) can see this row at all — `Tools/capture-live.sh`
        /// is the check.
        static var topBarLeading: CGFloat {
            trafficLightLeading + TrafficLightAlignment.rowWidth + trafficLightToGlyph
                - outerX - (28 - toolIcon) / 2
        }
        /// Text inset from the well edge (label x 62 → 31, well x 18 → 13).
        static let wellPadding: CGFloat = 13
        /// Section header height and the gap wells keep from headers.
        static let headerHeight: CGFloat = 26
        static let headerToWell: CGFloat = 6
        static let wellToHeader: CGFloat = 10
        /// Slider: track height, knob size.
        static let trackHeight: CGFloat = 2.5
        static let knobSize = CGSize(width: 10.5, height: 8.7)
        static let knobRadius: CGFloat = 3
        /// Column where every slider track starts inside a well (201 → 100.5,
        /// minus well x 18 → 82.5) and the value column width.
        static let sliderLabelWidth: CGFloat = 70
        static let sliderValueWidth: CGFloat = 40
        static let rowHeight: CGFloat = 20
        static let listRowHeight: CGFloat = 24
        /// Checkbox square (9.9 → 5) drawn with a 1 pt stroke.
        static let checkbox: CGFloat = 9
        /// Disclosure triangle (24.3×14.5 → 12×7).
        static let disclosure = CGSize(width: 12, height: 7)
        /// Section icon box.
        static let sectionIcon: CGFloat = 16
        /// Toolbar glyph size.
        static let toolIcon: CGFloat = 17
        /// Panel-header glyph size (import/export, sliders).
        static let panelIcon: CGFloat = 19
        /// Collapse tab (27.8×83.1 → 14×41.5).
        static let tabThickness: CGFloat = 14
        static let tabLength: CGFloat = 41.5
        /// Zoom pill (210.5×41.4 → 105×20.7).
        static let zoomPill = CGSize(width: 105, height: 20.7)
        static let filmCover: CGFloat = 20
        static let thumbHeight: CGFloat = 105
        static let minWindow = CGSize(width: 1100, height: 700)

        /// The export page's own geometry (RFC-018 §6).
        ///
        /// Measured from `reference_layout/Export_Page/export_page.svg` — the
        /// drawing itself, not a render of it. Its artboard is 3714.69 ×
        /// 2046.5 and the window in it is 2981.27 units wide; the scale below
        /// is **2**, the same one the editor's tokens use, and three of those
        /// tokens land on the drawing exactly: `cardRadius` and `wellRadius`
        /// are 30 and 22.85 units, and the quality knob is 21.07 × 17.44 —
        /// `knobSize` is 10.5 × 8.7. A drawing that reproduces three of
        /// another document's tokens at 2 shares its scale, so the export
        /// window is **1490.65 × 989.55 pt**, and every number below is the
        /// drawing's divided by two.
        ///
        /// Where this page and the editor differ they differ because the two
        /// drawings do: its bar is 30 pt rather than 41, its wells sit 6 pt
        /// from the card edge rather than 9, and its right-hand card is 221 pt
        /// rather than 286.
        ///
        /// The cards are **flush to the window's edges**, as the editor's are
        /// when the window is its design size — the drawing puts them at x 0
        /// and x 2543.83 of a 2981.27-wide window, so there is no outer margin
        /// and the only gap is the 6 pt between the bar and the cards.
        enum Export {
            /// Design window, so a capture can be taken at exactly the size
            /// the drawing describes.
            static let width: CGFloat = 1490.65
            static let height: CGFloat = 989.55

            static let leftWidth: CGFloat = 313.4
            static let rightWidth: CGFloat = 220.7
            static let topBarHeight: CGFloat = 29.9
            static let cardRadius: CGFloat = 15
            /// The bar-to-cards gap, which is also the gap between cards.
            static let gap: CGFloat = 5.8

            static let wellInset: CGFloat = 5.9
            static let wellRadius: CGFloat = 11.4
            static let wellPadding: CGFloat = 9.8
            static let wellVertical: CGFloat = 15

            /// Section rows: header height, the gap under it, and the gap a
            /// well keeps before the next header.
            static let headerHeight: CGFloat = 18
            static let headerToWell: CGFloat = 5
            static let wellToHeader: CGFloat = 11

            /// The label column a well's controls start after. The drawing's is
            /// 64.5, and "Existing File" and "Color Space" fit it *there*
            /// because its type is set with an optical size of 28
            /// (`font-variation-settings: … 'opsz' 28`), which is narrower than
            /// the text optical size the system hands a 10.5 pt face. Four
            /// points is the whole of the difference, and a truncated label is
            /// worse than a column four points wide.
            static let labelWidth: CGFloat = 68.5
            static let rowHeight: CGFloat = 14.7
            static let rowSpacing: CGFloat = 16.5

            /// The naming chips and the colour-space pill.
            static let chipHeight: CGFloat = 14.7
            static let chipSpacing: CGFloat = 2.1

            /// A recipe row in the Export Formula list, and the list's own
            /// height — the drawing gives the well 171 pt, of which the list
            /// gets 144 and the +/− row the rest.
            static let recipeRowHeight: CGFloat = 19.6
            static let recipeRowSpacing: CGFloat = 1.1
            static let formulaListHeight: CGFloat = 144

            /// A filmstrip cell: the long edge of a thumbnail, the margin the
            /// card keeps around one, and the room below it for its name.
            static let thumbMax: CGFloat = 185.6
            static let thumbMargin: CGFloat = 17.5
            static let cellLabelGap: CGFloat = 26

            /// The quality slider, from the drawing's own track and knob.
            static let trackWidth: CGFloat = 155.5
            static let trackHeight: CGFloat = 2.3

            /// Bar: where the window buttons and the mode toggle start, how
            /// big the toggle's glyphs are, and the gaps either side of the
            /// zoom pill. The count pill is centred over the filmstrip card
            /// rather than inset from the window edge — its centre is 0.65 pt
            /// from the card's — because it labels the strip below it.
            static let trafficLightLeading: CGFloat = 12.4
            static let modeToggleLeading: CGFloat = 330
            static let modeGlyph: CGFloat = 13.9
            static let modeSpacing: CGFloat = 0
            static let zoomClusterGap: CGFloat = 25
            static let pillWidth: CGFloat = 76.9
            static let pillHeight: CGFloat = 15.1
            /// The span the zoom cluster occupies, and therefore the width of
            /// the grid-size slider that replaces it in Grid mode: two 24 pt
            /// buttons, a 76.9 pt pill and two 25 pt gaps. Both states being
            /// the same width is what keeps the count pill still.
            static let zoomClusterWidth: CGFloat = 24 + zoomClusterGap + pillWidth
                + zoomClusterGap + 24
            /// The grid-size slider's stops — a **count of columns**, and the
            /// whole reason it is detented. 2 to 10 is Finder's own range and
            /// the user asked for Finder's feel; nothing in the drawing picks
            /// a count, so this is the one number on this page that is a
            /// judgement rather than a measurement.
            static let gridColumns: ClosedRange<Int> = 2...10
            static var countTrailingInset: CGFloat { rightWidth / 2 - pillWidth / 2 }
            static let zoomToCount: CGFloat = 87.5

            /// The proof sits on the ground with this much air around it.
            static let proofInset: CGFloat = 12
        }
    }

    // MARK: type ramp
    //
    // Cap height of "Kodak Portra 400" in the drawing: 16.9 units → 8.45 pt,
    // i.e. a 12 pt face. Headers share it. Labels are one step down.

    enum Font {
        static let sectionTitle = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let listItem = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let groupHeader = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let label = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let sublabel = SwiftUI.Font.system(size: 10, weight: .medium)
        static let value = SwiftUI.Font.system(size: 10.5, weight: .medium).monospacedDigit()
        static let tab = SwiftUI.Font.system(size: 10.5, weight: .semibold)
        static let caption = SwiftUI.Font.system(size: 9, weight: .regular)
        static let pill = SwiftUI.Font.system(size: 10.5, weight: .semibold).monospacedDigit()

        /// The export page's ramp — **the same sizes, in a heavier face**.
        /// The drawing sets `font-weight: 700` on every text class it has
        /// (`SFPro-Bold`), where the editor's sets semibold on the labels and
        /// regular on the captions. Its pixel sizes halve onto this ramp
        /// exactly: 21 px titles and labels → 10.5, 24 px list rows → 12,
        /// 18 px the quality readout → 9, 15.34 px the zoom pill → 8.
        enum Export {
            static let sectionTitle = SwiftUI.Font.system(size: 10.5, weight: .bold)
            static let label = SwiftUI.Font.system(size: 10.5, weight: .bold)
            static let listItem = SwiftUI.Font.system(size: 12, weight: .bold)
            static let chip = SwiftUI.Font.system(size: 10.5, weight: .bold)
            static let value = SwiftUI.Font.system(size: 9, weight: .bold)
            static let pill = SwiftUI.Font.system(size: 8, weight: .bold)
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
