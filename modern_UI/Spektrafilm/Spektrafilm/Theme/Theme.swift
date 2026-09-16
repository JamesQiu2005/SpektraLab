//  Theme.swift — every visual token in the interface, measured from the
//  drawing.
//
//  Two drawings, one file. The **editor** is
//  `modern_UI/reference_layout/Main/sample_frontend.svg` (2026-09-17), a
//  3840×2160 canvas — a 1920×1080 window at 2× — and every editor number
//  below is that drawing's value divided by two. The **export page** is
//  `reference_layout/Export_Page/export_page.svg` and keeps its own nested
//  `Metric.Export` / `Font.Export`; it was not redrawn and nothing here
//  changes it.
//
//  Nothing in a view file may carry a literal colour or size that could have
//  come from here — that is the rule that keeps the interface matching the
//  drawing when one token moves.
//
//  ## What the 2026-09-17 drawing changed
//
//  The four floating rounded cards on a ground are gone. The window is now
//  three flush regions — a full-height left rail, the centre, a full-height
//  right rail — with **1 pt hairlines** where the old design had gutters and
//  corner radii. There is no outer margin, no gutter and no card radius, so
//  `outerX`, `outerY` and `gutter` are not tokens any more: a rail that is
//  flush with the window's edge has nothing to be inset by. `cardRadius`
//  survives because the export page still draws rounded cards with it.
//
//  The one thing that still floats is the tool bar, a rounded pill on the
//  ground over the canvas (`barTop`/`barHeight`/`barRadius`).
//
//  The derivation of every number, and the drawing coordinate it came from,
//  is `modern_UI/design/TOKENS-main-2026-09-17.md`.

import SwiftUI

enum Theme {

    // MARK: colours
    //
    // The palette got *smaller*. The drawing draws pills, wells, slider
    // tracks and the canvas surround in one grey (`.st13`), the two rails and
    // the filmstrip in another (`.st15`), and separates functions with a
    // hairline instead of with a gap.

    /// `.st13` — the canvas surround, and also every well, pill and slider
    /// track. One grey, four jobs: the drawing uses *elevation* (a lighter
    /// shape on a darker rail) rather than a palette to say "this is a
    /// control".
    static let ground = Color(hex: 0x5F5F5F)
    /// `.st15` — the two rails and the filmstrip.
    static let card = Color(hex: 0x2C2D2B)
    /// A well inside a rail: the same value as the ground, on purpose.
    static let well = ground
    /// A pill or field sitting **on a rail** — the AE Method menu, a value
    /// field, the zoom pill. Ground-coloured, because that is what the
    /// drawing fills them with now that they no longer sit inside a well.
    static let pill = ground
    /// A pill sitting **inside a well** — the export page only, where the
    /// well is already ground-coloured and a control on it has to be darker
    /// to be seen at all. Do not use it on an editor rail.
    static let field = card
    /// `.st1` stroke, `#b5b5b6` at 2 units → **1 pt**. The hairline that
    /// separates one section from the next, and the rails from the filmstrip.
    /// It runs the full width of the rail — no inset — which is what makes
    /// the column read as a stack of rooms rather than a list of cards.
    static let rule = Color(hex: 0xB5B5B6)
    /// `.st12` — primary text and glyphs.
    static let text = Color(hex: 0xFAF8F4)
    /// `.st6` — dim captions and anything the interface is not asking you to
    /// read.
    static let dim = Color(hex: 0x898989)
    /// Secondary text on a rail: the "As Shot" caption under a slider.
    static let secondaryText = Color(hex: 0xDAD8D4)
    /// Plot grounds (histogram / curve) are one step darker than the rail.
    static let plot = Color(hex: 0x1E1F1E)
    static let plotGrid = Color(hex: 0x3A3B39)
    /// `.st17` / `.st3` fill, `.st2` stroke — the one accent in the
    /// interface. **`#eca650`, not the old `#ee8a2b`**: the new drawing names
    /// it in three places and the file that names the colour wins.
    static let accent = Color(hex: 0xECA650)
    /// `.st16` — a **chosen** row in the film or print list. The drawing's
    /// own words for what changed: "selected entries has shallow, instead of
    /// framed square around it, and the text turns from white to black". So
    /// selection is a full-width light band, not a frame, and the row's text
    /// inverts on it.
    static let selection = Color(hex: 0xC9CACA)
    /// Text on that band.
    static let onSelection = Color(hex: 0x0E0E0E)
    /// How far a control that cannot be used is taken down. The PRD makes
    /// this one rule for the whole app — "if one option is non-selectable,
    /// both the text and the input pill is greyed across the app" — so it is
    /// one number applied to the *row*, label and pill together
    /// (`View.rowEnabled(_:)`), rather than a second colour per element that
    /// each caller would have to remember to use.
    static let disabledOpacity: Double = 0.38
    /// The export page's accent, `.cls-12` in
    /// `reference_layout/Export_Page/export_page.svg`. **The user's own
    /// drawing says `#f08724`**, and that page follows its own drawing.
    static let exportAccent = Color(hex: 0xF08724)
    /// `.cls-21` — the naming chips' plate on the export page.
    static let exportChip = Color(hex: 0x686969)
    /// The white frame a filmstrip cell is marked with. Still a frame: the
    /// filmstrip is the one surface the redraw left alone, and a light band
    /// behind a photograph is not a mark you can see.
    static let selectionFrame = Color(hex: 0xFAF8F4)
    /// `.st18` — the slider knob, a hair warmer than `text` in the drawing.
    static let knob = Color(hex: 0xFBF8F3)
    static let canvasSurround = ground

    static let histR = Color(hex: 0xE8524E)
    static let histG = Color(hex: 0x62C462)
    static let histB = Color(hex: 0x5D7DE8)
    static let histY = Color(hex: 0xBDBDBD)

    // MARK: metrics (SVG ÷ 2)

    enum Metric {

        // MARK: the window's three regions
        //
        //      0        254                        1632      1920
        //      ┌─────────┬──────────────────────────┬─────────┐  0
        //      │ header  │      ▁▁▁▁ bar ▁▁▁▁       │ header  │  38
        //      ├─────────┤                          ├─────────┤
        //      │  left   │         canvas           │  right  │
        //      │  rail   │                          │  rail   │
        //      │         ├──────────────────────────┤         │  948
        //      │         │        filmstrip         │         │
        //      └─────────┴──────────────────────────┴─────────┘  1080
        //
        // The drawing's own rectangles, halved: the left rail is `x -2.6
        // w 509.9`, the right `x 3263.9 w 576.1`, the filmstrip `y 1895.3
        // h 264.7`, all of them running to the window's edge. There is no
        // outer margin and no gutter — the hairline is the separator.

        /// Left rail. The drawing's 509.9 / 2, rounded.
        static let leftPanelWidth: CGFloat = 254
        /// Right rail. The drawing's 576.1 / 2, rounded.
        static let rightPanelWidth: CGFloat = 288
        /// The filmstrip's own height, 264.7 / 2. It spans the centre column
        /// only: the two vertical hairlines at `x 508.8` and `x 3263.6`
        /// (y 1895…2160) are what the drawing separates it from the rails
        /// with.
        static let filmstripHeight: CGFloat = 132

        /// **Left, 232 … 380.** The floor is the Camera section's AE Method
        /// row, which is the widest thing on the rail: a 74 pt label column,
        /// 2 × 18 pt of row inset, and a pill that has to hold
        /// `center-weighted (legacy)` — the name a sidecar written before the
        /// field existed still meters by, and the one string in the interface
        /// nobody chose. That is ≈ 225 pt, so 232 is the drawing's own layout
        /// with seven points to spare.
        ///
        /// The ceiling is where the rail stops being a rail: past 380 the
        /// only thing that grows is a slider's track, which is already longer
        /// than the drawn one, and the film list's rows are mostly air.
        static var leftPanelRange: PanelWidthRange {
            PanelWidthRange(narrowest: 232, standard: leftPanelWidth, widest: 380)
        }

        /// **Right, 268 … 364**, unchanged from the previous drawing and for
        /// the reasons recorded then: the widest end is where the colour
        /// balance triangle reaches its own ceilings (`ColorBalanceLayout`
        /// clamps the midtone wheel to 64…120 pt and each side wheel to
        /// 44…96), and the narrow end is the five-tab row above it, measured
        /// to ellipsize at 276 and fit at 286. The new drawing's 288 sits two
        /// points above that floor, as the old one's 286 did.
        static var rightPanelRange: PanelWidthRange {
            PanelWidthRange(narrowest: 268, standard: rightPanelWidth, widest: 364)
        }

        /// The header row at the top of each rail: import / export / the
        /// sidebar toggle on the left, the adjustments glyph / the sidebar
        /// toggle on the right. The drawing's first hairline is at `y 75.6`,
        /// so 37.8 — rounded to 38, which also makes the traffic lights'
        /// centreline a whole number.
        static let panelHeaderHeight: CGFloat = 38
        /// Leading inset of a rail header's first glyph (`x 20.2 / 2`).
        static let panelHeaderLeading: CGFloat = 10
        /// Trailing inset of the sidebar toggle at the header's far end
        /// (the drawing's 254 − 245.3).
        static let panelHeaderTrailing: CGFloat = 9

        // MARK: the hairline
        //
        // `.st1`, `stroke: #b5b5b6; stroke-width: 2px` at 2× → 1 pt, and the
        // drawing runs it edge to edge (`line x1="-4" x2="505.9"`).

        static let rule: CGFloat = 1

        // MARK: the floating tool bar
        //
        // `rect x 529 y 9.4 w 2721 h 61.8 rx 28`, halved: a rounded pill on
        // the ground, over the canvas, spanning the centre column. It is the
        // one thing in the new drawing that still floats.

        /// Bar height, 61.8 / 2.
        static let topBarHeight: CGFloat = 31
        /// Corner radius, 28 / 2 — very nearly a capsule at this height, and
        /// the drawing's own number rather than `height / 2`.
        static let barRadius: CGFloat = 14
        /// Air above the bar, 9.4 / 2.
        static let barTop: CGFloat = 5
        /// Air each side of it. The drawing's are 11.1 leading and 6.95
        /// trailing, which is a sketch being a sketch: a bar that is not
        /// centred in its own column is a thing you can see. 9 is the mean.
        static let barInset: CGFloat = 9
        /// The strip the centre column reserves at its top: the bar, with its
        /// own air above and the same below. The bar therefore sits **over**
        /// ground rather than over the picture — which is the drawing (the
        /// `.st13` ground rectangle runs behind it) and is also the only
        /// arrangement in which a maximised frame is not partly under a
        /// toolbar.
        static var barStrip: CGFloat { barTop * 2 + topBarHeight }
        /// Leading inset of the bar's first control, from the bar's own edge,
        /// when the left rail is open and the window buttons are on it.
        static let barPadding: CGFloat = 12

        // MARK: the window buttons
        //
        // `.windowStyle(.hiddenTitleBar)` does not remove the three buttons;
        // it floats them over the content. They are *placed*
        // (`Windows/TrafficLights.swift`), and the row they are placed on is
        // the **rail header's**, which is the window's first row at
        // `y 0…38` — the same row the bar's centre falls in.
        //
        // That is why they do not move when the left rail folds: the rail
        // header and the bar strip occupy the same 38 pt of window, so one
        // centreline serves both. What changes is only which of the two
        // *reserves* the space — the header when the rail is open, the bar
        // when it is not.

        static let trafficLightLeading: CGFloat = 20
        static var trafficLightCentreY: CGFloat { panelHeaderHeight / 2 }
        /// Gap between the zoom button and the first glyph after it. Xcode's
        /// is about this; below ~12 the glyph reads as a fourth window button.
        static let trafficLightToGlyph: CGFloat = 16
        /// How much of a row the buttons take, from its leading edge — what
        /// a header or a bar has to skip before its own first control.
        static var trafficLightClearance: CGFloat {
            trafficLightLeading + TrafficLightAlignment.rowWidth + trafficLightToGlyph
        }
        /// The same clearance, measured from the **bar's** leading edge
        /// rather than the window's, for the case where the left rail is
        /// folded and the bar is the row the buttons sit on.
        static var barLeadingWithButtons: CGFloat { trafficLightClearance - barInset }

        // MARK: a section on a rail
        //
        // A section is a header row, its content, and a hairline. Measured
        // off the two rails' hairlines: White Balance and Exposure are drawn
        // collapsed and are 29.05 and 31.05 apart, so a header row is 30; the
        // Camera and Histogram headers put their content 27.25 and 30.75
        // below the rule above them, which is the same 30 within the
        // drawing's own noise.

        static let headerHeight: CGFloat = 30
        /// Air under a section's content, before the next hairline. The
        /// drawing's are 14.6 (Camera), 10 (Film) and 10.75 (Print).
        static let sectionBottom: CGFloat = 12
        /// Leading inset of the disclosure triangle's 18 pt box, so the
        /// triangle itself lands on the drawing's x 11.
        static let headerLeading: CGFloat = 7
        /// Gap between that box and the title, so the title lands on the
        /// drawing's x 32.
        static let headerTitleGap: CGFloat = 7
        /// Trailing inset of the "•••" menu.
        static let headerTrailing: CGFloat = 10
        /// Disclosure triangle (24.3 × 14.5 → 12 × 7).
        static let disclosure = CGSize(width: 12, height: 7)

        // MARK: a row on a rail
        //
        // Every control row is inset 18 from both edges of the rail, the
        // label takes a fixed column, and the control takes what is left —
        // measured off the drawing: labels start at 17.6 and the value pills
        // end at 235.6 on a 254 pt rail.

        /// Inset of a control row from both edges of the rail.
        static let rowInset: CGFloat = 18
        /// The line box one control sits in.
        static let rowHeight: CGFloat = 20
        /// A control's own height — every pill, field and menu in the
        /// interface (the drawing's 27.8 / 2).
        static let controlHeight: CGFloat = 14
        /// Between two row blocks.
        static let rowSpacing: CGFloat = 5
        /// The second line of a slider row: "As Shot" and its box.
        static let subRowHeight: CGFloat = 15
        /// The label column. The drawing's is 68.35 (its labels start at
        /// 17.6 and its first control at 86.35) and `Film Exposure` fills
        /// 66 of it *there*, at Illustrator's optical size. macOS sets the
        /// same string wider, so the column is 74 — a truncated label is
        /// worse than a column six points wide.
        static let sliderLabelWidth: CGFloat = 74
        /// The value pill at the end of a slider row (87.5 / 2).
        static let sliderValueWidth: CGFloat = 44
        /// Between the track and that pill (191.85 − 176.8).
        static let sliderValueGap: CGFloat = 14
        /// A picker that does **not** fill its row — Film Type, Side, and the
        /// unit pill beside Side Length. The drawing draws them 107 wide and
        /// right-aligned, where AE Method fills everything after its label.
        static let pickerWidth: CGFloat = 112
        /// The number field beside Side Length (99.5 / 2), and the unit pill
        /// after it (76.6 / 2).
        static let fieldWidth: CGFloat = 50
        static let unitWidth: CGFloat = 38
        /// A label-and-checkbox row (Grain / Halation / Glare / Lens
        /// Correction): the drawing's pitch is 21.25–22.25.
        static let toggleRowHeight: CGFloat = 17
        /// Corner radius of a control that is **not** a capsule: the value
        /// pills and the Side Length field, drawn `rx 8.5` against the
        /// menus' `rx 13.9` (= half their height, i.e. a capsule).
        static let fieldRadius: CGFloat = 4.25

        // MARK: the film and print lists

        /// How far a list well is inset from the rail's edges (the drawing's
        /// 4.7 leading, 3.45 trailing).
        static let wellInset: CGFloat = 4
        /// Well corner radius (22.9 → 11.5).
        static let wellRadius: CGFloat = 11.5
        /// Text inset inside a well, and inside a list row.
        static let wellPadding: CGFloat = 12
        /// A row in the film or print list (39.2 / 2). The selection band is
        /// exactly this tall and exactly the well's width, which is what
        /// "shallow, instead of framed square" means.
        static let listRowHeight: CGFloat = 19.5
        /// The `CINE` pill after a cinema stock: 55.2 × 20.6 → 27.6 × 10.3,
        /// a 1 pt accent stroke, no fill, 10.75 in from the well's edge.
        static let cinePill = CGSize(width: 28, height: 11)
        static let cinePillTrailing: CGFloat = 11

        // MARK: the two actions under the print list

        /// Process / Original: 52.6 / 2 tall, `rx 16.5` → 8.25, 2.25 apart,
        /// and inset by the same 4 the wells above them are.
        static let actionHeight: CGFloat = 26
        static let actionRadius: CGFloat = 8.25
        static let actionGap: CGFloat = 2.5

        // MARK: sliders

        /// Track height, 2.7 / 2. Thin, and the drawing means it: the track
        /// is the same grey as the ground, so weight is the only thing
        /// separating it from a divider.
        static let trackHeight: CGFloat = 1.5
        /// The knob. The drawing's is `12.3 × 10.1 rx 5.1` → 6.15 × 5.05,
        /// fully rounded — a dot. 7 is that, rounded up to something a
        /// pointer can find.
        static let knobSize = CGSize(width: 7, height: 7)
        static let knobRadius: CGFloat = 3.5
        /// The checkbox. `9.9 × 9.9` with a 1 pt `#faf8f4` stroke → 5 pt of
        /// accent inside a white box; 8 is that at a size the eye resolves,
        /// and its hit area is padded well past it.
        static let checkbox: CGFloat = 8

        // MARK: glyphs

        /// A tool glyph on the floating bar (the drawing's are 17.6–21.5 pt
        /// tall; an SF Symbol at 15 sets about that).
        static let toolIcon: CGFloat = 15
        /// A rail header's glyph — import, export, the adjustments sliders.
        static let panelIcon: CGFloat = 16
        /// `sidebar.left` / `sidebar.right`, the two buttons that fold a rail
        /// and that the PRD requires to be on screen at every moment
        /// (41.8 × 32.7 → 20.9 × 16.35).
        static let sidebarIcon: CGFloat = 15
        /// Kept for the export page's section headers, which still draw one.
        static let sectionIcon: CGFloat = 16

        // MARK: the filmstrip, and the one tab that survived
        //
        // The drawing replaced the left and right collapse tabs with the two
        // sidebar buttons. The **bottom** one is unchanged — "except the
        // bottom gallery view remains unchanged" — and is still the pill on
        // the canvas edge (`rect 27.8 × 83.1 rx 13.9`, rotated).

        static let tabThickness: CGFloat = 14
        static let tabLength: CGFloat = 41.5
        /// Thumbnail height inside the 132 pt strip.
        static let thumbHeight: CGFloat = 110
        static let filmCover: CGFloat = 18

        /// The zoom pill on the bar (210.5 × 41.4 → 105 × 20.7). It carries
        /// **no stroke** in the new drawing; it is a plain `.st13` capsule
        /// like every other pill.
        static let zoomPill = CGSize(width: 105, height: 20.7)

        static let minWindow = CGSize(width: 1100, height: 700)

        /// Card corner radius — the **export page's** (`rx 30 → 15`). The
        /// editor's cards are flush and square now; `panelCard()` is the
        /// export page's card, `railCard()` is the editor's.
        static let cardRadius: CGFloat = 15

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

            /// The drawing's own card widths. They are the `standard` of the
            /// ranges below rather than the only size the cards have: the user
            /// asked for a tab that is "non-fixed … one narrowest and widest
            /// for both the collapse tabs", so the page opens exactly as drawn
            /// and the edge moves from there.
            static let leftWidth: CGFloat = 313.4
            static let rightWidth: CGFloat = 220.7

            /// **A judgement, and the reasoning, because nothing in the
            /// drawing bounds a card it draws at one size.**
            ///
            /// *Left, narrowest 272.* The card's own content is
            /// `W − 31.4` — `wellInset` and `wellPadding` on both sides — and
            /// the widest thing that must not be squeezed is the Naming row:
            /// the label column at 68.5 and four chips at 168, measured off a
            /// capture. 272 leaves that row 240.6 against the 236.5 it needs,
            /// so the floor is the chip row and about six points of air. It is
            /// the label column that sets it — at the drawing's own 64.5 the
            /// row would need four points less, and it is macOS's wider optical
            /// size that put it at 68.5.
            ///
            /// *Left, widest 460* and *right, widest 360.* The proof is what
            /// this page exists to show, so the bound is where the cards start
            /// eating it. Both at their widest leave the centre 670.7 of the
            /// window's 1490.65 — 45 %, against 64 % at standard — and still
            /// wider than either card. Past that the page is two lists with a
            /// picture between them.
            ///
            /// *Right, narrowest 160.* The card is `W − 35` of thumbnail, and
            /// the drawing's thumbnail is 185.6. Two thirds of that is 124,
            /// which is where a 3:2 frame is still a picture of a photograph
            /// rather than a coloured chip — the film's own character is what
            /// the strip is for, and it is illegible below about there. 124 +
            /// 35 is 159, rounded to 160.
            static let leftRange = PanelWidthRange(narrowest: 272, standard: leftWidth, widest: 460)
            static let rightRange = PanelWidthRange(narrowest: 160, standard: rightWidth, widest: 360)
            /// **28, not the drawing's 29.9** — the user's "could be narrower
            /// overall", and 28 is as far as it goes.
            ///
            /// The bar's floor is not set by anything this page draws. Its
            /// tallest control is the 15.1 pt pill, which would be comfortable
            /// at 24; the three **window buttons** are AppKit's, 14 pt across,
            /// and `TrafficLightAlignment` puts them on the bar's centreline.
            /// macOS gives those buttons a 28 pt title bar — 7 pt of air above
            /// and below — and 28 is that number. Below it the buttons are
            /// being squeezed rather than the bar tightened, which is a
            /// different thing from a slimmer row.
            ///
            /// The user's decision, in as many words: "the top should be
            /// fixed though, could be narrower overall." Fixed it is, and
            /// this is the narrower.
            static let topBarHeight: CGFloat = 28
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

            /// **Grid mode.** The drawing's grid card is the centre pane and
            /// the filmstrip as one card: it starts just right of the
            /// settings card and runs to the window's right edge, and the grid
            /// lives inside it rather than in the centre alone.
            static let gridWidth: CGFloat = 2350.54 / 2
            /// The drawing's gap between the settings card and the grid card:
            /// 7.81 units, 3.9 pt, and *not* the 5.8 pt `gap` the bar keeps
            /// from the cards — two different numbers in the same drawing.
            ///
            /// **Unused, deliberately.** The resize handle has to sit between
            /// those two cards in both modes or the settings card cannot be
            /// dragged in Grid, and it is 6 pt, so the handle *is* the gap and
            /// this is the number it stands in for. Kept rather than deleted
            /// so the drawing's value is on the record beside the one that is
            /// actually drawn.
            static let gridGap: CGFloat = 3.905
            /// Leading and top inset of the grid inside its card. The drawing
            /// puts the first cell 67.34 units in and 120.51 down — 33.7 and
            /// 60.25 pt — and the trailing slack falls out as one column gap,
            /// because the row is laid out from the leading edge rather than
            /// centred.
            static let gridPadding: CGFloat = 33.7
            static let gridTopInset: CGFloat = 60.25
            /// How much of its column a thumbnail takes. The drawing's cells
            /// are 307.88 units wide on a 457.68-unit pitch — 0.66 — so the
            /// gap between two thumbnails is the other third of the pitch, at
            /// every column count the slider can reach.
            static let gridCellFraction: CGFloat = 0.66
            /// Between two rows. **A judgement**: the drawing has one row and
            /// does not say. Smaller than the column gap because the name
            /// under a thumbnail is not a thumbnail.
            static let gridRowSpacing: CGFloat = 28

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
            /// the user asked for Finder's feel; the drawing shows five of
            /// them, which is one stop of this.
            static let gridColumns: ClosedRange<Int> = 2...10
            static var countTrailingInset: CGFloat { rightWidth / 2 - pillWidth / 2 }
            static let zoomToCount: CGFloat = 87.5

            /// The proof sits on the ground with this much air around it.
            static let proofInset: CGFloat = 12
        }
    }

    // MARK: type ramp
    //
    // Measured off the drawing's outlines. Cap heights, halved: a section
    // title ("Camera", "White Balance") is 8.1–8.8 pt, so a 12 pt face; a row
    // label and a list row are 7.25, so 10.5; "As Shot" is smaller again, and
    // the two actions under the print list are set a step up from a label.
    //
    // Everything on this rail is **semibold or heavier**. The drawing sets
    // every string in a bold face, and at 10.5 pt on a dark ground a regular
    // weight disappears.

    enum Font {
        static let sectionTitle = SwiftUI.Font.system(size: 12, weight: .bold)
        /// A row in the film or print list.
        static let listItem = SwiftUI.Font.system(size: 10.5, weight: .semibold)
        static let groupHeader = SwiftUI.Font.system(size: 10, weight: .semibold)
        /// A control row's label, and the value inside a menu pill.
        static let label = SwiftUI.Font.system(size: 10.5, weight: .semibold)
        /// "As Shot", and any second line under a label.
        static let sublabel = SwiftUI.Font.system(size: 9, weight: .medium)
        /// A number in a value pill or a field.
        static let value = SwiftUI.Font.system(size: 10.5, weight: .medium).monospacedDigit()
        static let tab = SwiftUI.Font.system(size: 10.5, weight: .semibold)
        static let caption = SwiftUI.Font.system(size: 9, weight: .regular)
        static let pill = SwiftUI.Font.system(size: 10, weight: .semibold).monospacedDigit()
        /// Process / Original, one step up from a label.
        static let action = SwiftUI.Font.system(size: 11.5, weight: .semibold)
        /// The `CINE` pill. Small, and the drawing draws it small: 27.6 pt of
        /// pill has to hold four letters and its own padding.
        static let cine = SwiftUI.Font.system(size: 7, weight: .bold)

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

/// The 1 pt `#b5b5b6` line the drawing separates every function with.
///
/// Full bleed, always: the drawing runs it from `x -4` to `x 505.9` on a rail
/// whose own edges are 0 and 254, which is a person drawing "edge to edge"
/// rather than a measurement. A rule with an inset reads as a list separator;
/// a rule without one reads as a wall, and a wall is what the new layout is
/// made of.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.rule)
            .frame(height: Theme.Metric.rule)
            .frame(maxWidth: .infinity)
    }
}

/// The vertical member of the same wall — between the filmstrip and a rail
/// (the drawing's `line x1="508.8" y1="1895.1" y2="2160.2"`).
struct VerticalHairline: View {
    var body: some View {
        Rectangle().fill(Theme.rule)
            .frame(width: Theme.Metric.rule)
            .frame(maxHeight: .infinity)
    }
}

extension View {
    /// "If one option is non-selectable, both the text and the input pill is
    /// greyed across the app" (PRD).
    ///
    /// One modifier on the **row**, rather than a disabled colour each label
    /// and each pill has to remember: the rule is about a row, every row in
    /// the interface is a label and a control, and a rule spelled once cannot
    /// be applied to one half of a row and not the other. It also stops the
    /// row taking the mouse, which is the other half of "non-selectable" —
    /// a greyed control that still opens its menu is worse than one that
    /// looks live.
    func rowEnabled(_ enabled: Bool, because reason: String = "") -> some View {
        self.opacity(enabled ? 1 : Theme.disabledOpacity)
            .allowsHitTesting(enabled)
            .modifier(DisabledReason(show: !enabled && !reason.isEmpty, reason: reason))
    }
}

/// `.help("")` still installs an empty tooltip, so the explanation has to be
/// attached conditionally rather than passed empty.
private struct DisabledReason: ViewModifier {
    let show: Bool
    let reason: String
    func body(content: Content) -> some View {
        if show { content.help(reason) } else { content }
    }
}
