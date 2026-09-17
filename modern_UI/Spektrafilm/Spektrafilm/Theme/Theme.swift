//  Theme.swift — every visual token in the interface, measured from the
//  drawing.
//
//  Two drawings, one file. The **editor** is
//  `modern_UI/reference_layout/Main/sample_frontend_v3.ai` (2026-09-18), a
//  3840×2160 artboard — a 1920×1080 window at 2× — and every editor number
//  below is that drawing's value divided by two. The **export page** is
//  `reference_layout/Export_Page/export_page.svg` and keeps its own nested
//  `Metric.Export`.
//
//  The 2026-09-17 drawing this replaced, `sample_frontend.svg`, is **no
//  longer in the repository**; the prose below that measures it is history,
//  and `design/TOKENS-main-2026-09-17.md` says which of its numbers v3 left
//  alone. Where the two disagree, v3 wins.
//
//  `Font.Export` is **no longer its own ramp**: it aliases the editor's, so
//  the two pages agree about what a label and a list row are. The page's own
//  *metrics* are still its drawing's — tighter rows and a narrower label
//  column — which is why `Metric.Export` stays.
//
//  Nothing in a view file may carry a literal colour or size that could have
//  come from here — that is the rule that keeps the interface matching the
//  drawing when one token moves.
//
//  ## What the v3 drawing changed (2026-09-18)
//
//  `design/TOKENS-main-v3-2026-09-18.md` translates
//  `reference_layout/Main/sample_frontend_v3.ai`, and it is the current
//  target — read it before the 2026-09-17 derivation below, which it
//  supersedes where the two disagree. The four changes with structure behind
//  them:
//
//  - **The tool bar stopped floating.** `barTop`, `barInset` and `barRadius`
//    are 0 and `topBarHeight` is 38, flush with both rails and the top edge
//    and aligned to the rail headers' own 38. Nothing in the window floats
//    any more.
//  - **The rail dividers run the full window height**, canvas included. The
//    older rule — that only the filmstrip needs a vertical line, because
//    elsewhere the ground colour separates rail from canvas — is superseded.
//    They stay overlays, so the three-column arithmetic is unchanged.
//  - **The stock lists sit on the rail.** No lighter well plate, no outer
//    clipping radius; the *selection* is what is rounded and inset, and it is
//    white with near-black text.
//  - **Two type sizes, not one.** The left rail's section titles are 12 and
//    the right rail's are 10.5, so `sectionTitle` split into
//    `leftSectionTitle` / `rightSectionTitle`. Control labels split the same
//    way: Camera's are 9, Film's are 10.5.
//
//  The palette values below marked "v3 sample" are sampled from
//  `layout_screenshot.png`, not recovered Illustrator swatches — §4 of the
//  handoff says so, and §8.7 leaves colour equivalence as an open QA item.
//
//  ## What the 2026-09-17 drawing changed
//
//  The four floating rounded cards on a ground are gone. The window is now
//  three flush regions — a full-height left rail, the centre, a full-height
//  right rail — with **1 pt hairlines** where the old design had gutters and
//  corner radii. There is no outer margin, no gutter and no card radius, so
//  `outerX`, `outerY` and `gutter` are not tokens any more: a rail that is
//  flush with the window's edge has nothing to be inset by. The export page
//  was the last card and is a rail now too, so `cardRadius` records a shape
//  nothing draws.
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
    static let ground = Color(hex: 0x5F5F5F)   // v3 sample: unchanged
    /// `.st15` — the two rails, the tool bar and the filmstrip.
    ///
    /// v3 sample `#2D2D2C`, one point off the 2026-09-17 value. Taken, not
    /// rounded back: the tool bar is this colour now too, so the rail and the
    /// bar meeting at a hairline is the one place a one-point difference
    /// would have shown as a seam.
    static let card = Color(hex: 0x2D2D2C)
    /// A well inside a rail: the same value as the ground, on purpose.
    static let well = ground
    /// A pill or field sitting **on a rail** — the AE Method menu, a value
    /// field, the zoom pill. Ground-coloured, because that is what the
    /// drawing fills them with now that they no longer sit inside a well.
    static let pill = ground
    /// A pill sitting **inside a well**, where the well is already
    /// ground-coloured and a control on it has to be darker to be seen at
    /// all. Do not use it on a rail.
    ///
    /// Nothing uses it at the moment. It was the export page's plate for
    /// every pill and field on the page, which was right while those rows sat
    /// inside wells and became invisible the moment they did not: `field` is
    /// `card`, so a pill drawn in it on a bare rail is a pill the same colour
    /// as the rail. That is what made the page's controls look like three
    /// different species — some capsules, some bare text.
    static let field = card
    /// `.st1` stroke, `#b5b5b6` at 2 units → **1 pt**. The hairline that
    /// separates one section from the next, and the rails from the filmstrip.
    /// It runs the full width of the rail — no inset — which is what makes
    /// the column read as a stack of rooms rather than a list of cards.
    static let rule = Color(hex: 0xB5B6B6)   // v3 sample
    /// `.st12` — primary text and glyphs.
    static let text = Color(hex: 0xF9F7F3)   // v3 sample
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
    static let accent = Color(hex: 0xE1A95F)
    /// `.st16` — a **chosen** row in the film or print list. The drawing's
    /// own words for what changed: "selected entries has shallow, instead of
    /// framed square around it, and the text turns from white to black". So
    /// selection is a full-width light band, not a frame, and the row's text
    /// inverts on it.
    /// **v3: white, and the band is rounded and inset** rather than running
    /// the well's full width. The mark moved from `#c9caca` at full width to
    /// `#ffffff` inside a capsule, which is the one selection treatment in
    /// the interface loud enough to be found in a list of 28 without a frame.
    static let selection = Color(hex: 0xFFFFFF)
    /// Text on that band. v3 sample `#0f0e0e`.
    static let onSelection = Color(hex: 0x0F0E0E)
    /// The rail under a stock list.
    ///
    /// **`card`, not `well`.** v3 puts the film and print lists directly on
    /// the rail with no lighter plate under them, so the list's ground is the
    /// rail's. Its own name rather than `card` at the call site because
    /// "the stock list has no plate" is the decision, and a later drawing
    /// that gives it one back should move one token.
    static let stockList = card
    /// How far a control that cannot be used is taken down. The PRD makes
    /// this one rule for the whole app — "if one option is non-selectable,
    /// both the text and the input pill is greyed across the app" — so it is
    /// one number applied to the *row*, label and pill together
    /// (`View.rowEnabled(_:)`), rather than a second colour per element that
    /// each caller would have to remember to use.
    static let disabledOpacity: Double = 0.38
    /// The export page's accent — **now the same one**.
    ///
    /// `reference_layout/Export_Page/export_page.svg` names `#f08724` in
    /// `.cls-12`, and the page followed its own drawing while the editor
    /// moved to `#eca650` with the 2026-09-17 redraw. The result is two
    /// oranges a visible step apart in the same window: the naming chips
    /// against the film list's `CINE` pill, one page apart. The user's note is
    /// that this page "doesn't really match the style as the actual
    /// frontend", and an accent is the one colour in the palette whose whole
    /// job is to be recognised, so it cannot be two colours.
    ///
    /// The later drawing wins, as it did when it renamed the accent in the
    /// first place. Kept as its own name rather than deleted so the export
    /// drawing's value stays on the record and one line puts it back.
    static let exportAccent = accent
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

        // MARK: the tool bar
        //
        // **v3: it does not float.** The drawing fills the centre column's
        // top with a plain rectangle from `y .59` to `y 75.59` — flush with
        // both rails and with the window's top edge, no radius, no air. Its
        // 38 pt is the rail headers' 38 pt, so the three regions share one
        // top row and the traffic lights' centreline is the same in all of
        // them.

        /// Bar height, `(75.59 − .59) / 2` = 37.5, taken as the rail header's
        /// own 38 so the two cannot drift apart by half a point.
        static let topBarHeight: CGFloat = panelHeaderHeight
        /// **Zero.** Kept as tokens rather than deleted because the views read
        /// them and because a later drawing that floats the bar again should
        /// be three numbers rather than a re-plumbing — but a flush bar has
        /// no radius and nothing to be inset by.
        static let barRadius: CGFloat = 0
        static let barTop: CGFloat = 0
        static let barInset: CGFloat = 0
        /// The strip the centre column reserves at its top. With no air above
        /// or below the bar this **is** the bar, which is the point: there is
        /// no ground strip behind it any more, so a maximised frame starts
        /// directly under a surface rather than under a floating pill with
        /// ground showing round it.
        static var barStrip: CGFloat { barTop * 2 + topBarHeight }
        /// Leading (and trailing) inset of the bar's own controls, from its
        /// edge. v3's first tool centre is x 303.12 at 1920 pt, i.e. 49 pt
        /// past the 254 pt rail; the tools are drawn in 28 pt boxes, so the
        /// content inset is 32 and the glyph lands on 46 + 3.
        static let barPadding: CGFloat = 32
        /// Between two tools. v3's centres are 303.12, ~363 and 425.22 — a
        /// pitch of 61 — which on a 28 pt box is a 33 pt gap.
        static let toolGap: CGFloat = 33
        /// The zoom cluster's own gaps, either side of the pill. The drawing's
        /// are 29.4 pt glyph-to-pill, and the glyph sits in a 28 pt box.
        static let zoomGap: CGFloat = 23
        /// Before/after to the zoom cluster, and the zoom cluster to the full
        /// screen button. **The drawing's are 63.6 and 85.2**, and these are
        /// not: at the minimum window (1100 pt, so a 540 pt bar) the drawing's
        /// spacing puts the two clusters 19 pt wider than the bar they are on,
        /// and a bar whose ends fall off the bar is worse than a bar that
        /// breathes slightly less. 40 and 46 keep the drawing's *shape* — the
        /// right-hand cluster spread out, with its widest gap before the last
        /// button — inside 523 pt.
        static let beforeAfterGap: CGFloat = 40
        static let fullScreenGap: CGFloat = 46
        /// The before/after glyph: the drawing's two rectangles side by side,
        /// `20.1 + 21.3` units wide of 30.1 tall, halved and rounded.
        static let beforeAfterIcon = CGSize(width: 25, height: 16)

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
        /// drawing's are 14.6 (Camera), 10 (Film) and 10.75 (Print) — but
        /// those are the gaps *below* content that already sits on roomier
        /// rows. Taken with `rowSpacing` below, 16 is what reproduces the
        /// drawing's own breathing: its largest gap inside the left rail
        /// measures 35.5 pt against the built rail's 24.
        static let sectionBottom: CGFloat = 16
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

        /// Inset of a control row from both edges of the rail. v3 measures
        /// its labels at x 15.61…17.12, so 16.
        static let rowInset: CGFloat = 16
        /// The line box one control sits in.
        static let rowHeight: CGFloat = 22
        /// A control's own height — every pill, field and menu in the
        /// interface (27.8 / 2 = 13.9, which v3 confirms).
        static let controlHeight: CGFloat = 13.9
        /// Between two row blocks.
        ///
        /// This and `rowHeight` are where "everything is vertically
        /// compressed" was. At 20/5 the nine rows of the Camera section
        /// closed 36 pt earlier than the drawing's; 22/9 is that 36 pt given
        /// back to the gaps rather than to the rows, because the drawing's
        /// rows are not tall — its *spaces* are.
        static let rowSpacing: CGFloat = 9
        /// The second line of a slider row: "As Shot" and its box.
        static let subRowHeight: CGFloat = 16
        /// The label column. The drawing's is 68.35 (its labels start at
        /// 17.6 and its first control at 86.35) and `Film Exposure` fills
        /// 66 of it *there*, at Illustrator's optical size. macOS sets the
        /// same string wider, so the column is 74 — a truncated label is
        /// worse than a column six points wide.
        static let sliderLabelWidth: CGFloat = 84
        /// Camera's own label column. v3 puts its track and menu at x 86.35
        /// and its labels at 16, so 70 — narrower than the shared 84, and
        /// `Film Exposure` is the string that has to fit. Film's rows keep
        /// the wider shared column: their labels are set at 10.5 rather than
        /// Camera's 9 and `Side Length` is the longest of them.
        static let cameraLabelWidth: CGFloat = 70
        /// Camera's metering menu fills the row after that column
        /// (298.44 / 2), and its slider tracks are 90.44 at the reference
        /// rail width. Both grow with the rail; they are recorded so a
        /// capture can be measured against them.
        static let cameraMeteringWidth: CGFloat = 149.22
        static let cameraTrackWidth: CGFloat = 90.44
        /// The value pill at the end of a slider row (87.5 / 2).
        static let sliderValueWidth: CGFloat = 43.73
        /// Between the track and that pill (191.85 − 176.8).
        static let sliderValueGap: CGFloat = 15.06
        /// A picker that does **not** fill its row — Film Type, Side, and the
        /// unit pill beside Side Length. The drawing draws them 107 wide and
        /// right-aligned, where AE Method fills everything after its label.
        static let pickerWidth: CGFloat = 107.03
        /// The number field beside Side Length (99.5 / 2), and the unit pill
        /// after it (76.6 / 2).
        static let fieldWidth: CGFloat = 49.77
        static let unitWidth: CGFloat = 38.32
        /// Trailing inset of Film's own controls: v3 ends their right edges
        /// at x 231.10 on a 254 pt rail. Wider than `rowInset` on purpose —
        /// the pickers are right-aligned and the drawing holds them further
        /// off the edge than it holds the labels.
        static let filmControlTrailingInset: CGFloat = 23
        /// Film's row pitch: v3's label baselines are 45 units apart.
        static let filmRowPitch: CGFloat = 22.5
        /// The Temperature / Tint text pitch in Camera (≈19.87).
        static let wbAxisPitch: CGFloat = 20
        /// A label-and-checkbox row (Grain / Halation / Glare / Lens
        /// Correction): the drawing's pitch is 21.25–22.25, and 17 was under
        /// the bottom of that range rather than in it.
        static let toggleRowHeight: CGFloat = 21
        /// Corner radius of a control that is **not** a capsule: the value
        /// pills and the Side Length field, drawn `rx 8.5` against the
        /// menus' `rx 13.9` (= half their height, i.e. a capsule).
        static let fieldRadius: CGFloat = 4.25

        /// Inset of a **plot** from the rail's edges — the histogram and the
        /// curve, which are pictures rather than rows and so do not take the
        /// row inset. The drawing's are 7.8 and 15.45 on a 288 pt rail; 12 is
        /// between them and is what makes the two line up with each other,
        /// which the drawing's do not.
        static let plotInset: CGFloat = 12

        // MARK: the film and print lists
        //
        // **v3 took the plate away.** The lists sit directly on the rail
        // (`Theme.stockList`), with no lighter well behind them and no outer
        // clipping radius — so the numbers below that describe a *well* now
        // describe only the export page's recipe list, which still has one.
        // What marks the chosen row is the `stock*` group further down: a
        // white capsule, inset from both edges and 15.27 pt tall.

        /// How far a list well is inset from the rail's edges (the drawing's
        /// 4.7 leading, 3.45 trailing). Export page only now.
        static let wellInset: CGFloat = 4
        /// Well corner radius (22.9 → 11.5).
        static let wellRadius: CGFloat = 11.5
        /// Text inset inside a well, and inside a list row.
        static let wellPadding: CGFloat = 12
        /// Air above the first row and below the last, **inside** the well.
        ///
        /// Without it the rows run flush to the well's own edge, so the
        /// 11.5 pt corner radius cuts the corners off the first and last
        /// rows and the selection band — a row that ends in a curve reads as
        /// a row that has been sliced. The drawing insets them; this is that
        /// inset, and it is also what stops a scrolled list presenting a
        /// half-row against the boundary.
        static let wellVPadding: CGFloat = 8
        /// A row in the film or print list. v3's list text baselines are 36
        /// units apart, so the pitch is **18** — and the row is the pitch,
        /// not the mark: the white capsule inside it is 15.27, which is what
        /// makes a selected row read as marked rather than as a filled cell.
        static let listRowHeight: CGFloat = 18
        /// The selection capsule: 30.53 / 2 tall, radius half of that.
        static let stockSelectionHeight: CGFloat = 15.27
        static let stockSelectionRadius: CGFloat = 7.63
        /// Where that capsule starts and ends. v3 draws it from x 33.57 / 2
        /// to x 227.52 on a 254 pt rail — so 16.79 in at the leading edge and
        /// 26.48 off the trailing one, which is why it is *not* symmetric and
        /// why the list cannot be padded with one number.
        static let stockLeadingInset: CGFloat = 16.79
        static let stockTrailingInset: CGFloat = 26.48
        /// And where the row's text starts, 42.66 / 2 — inside the capsule,
        /// not flush with it.
        static let stockTextLeadingInset: CGFloat = 21.33
        /// The list's scroll indicator (6.08 / 2). Its *height* reflects the
        /// scroll state; only the width is drawn art.
        static let stockScrollIndicatorWidth: CGFloat = 3.04
        /// The `CINE` pill after a cinema stock (v3 vector bounds), a 1 pt
        /// accent stroke, no fill.
        static let cinePill = CGSize(width: 21.59, height: 8.07)
        static let cinePillTrailing: CGFloat = 11

        // MARK: the two actions under the print list

        /// v3 draws them 165.72 × 37.03 → **82.86 × 18.52**: two capsules
        /// side by side at their own width, not two halves of the rail. The
        /// second starts at x 108.37 and the first ends at 96.19, so the gap
        /// is 12.18 and the pair is inset 13.33 from the rail's leading edge.
        static let actionSize = CGSize(width: 82.86, height: 18.52)
        static let actionRadius: CGFloat = 9.26
        static let actionGap: CGFloat = 12.18
        static let actionLeading: CGFloat = 13.33

        // MARK: sliders

        // The three numbers below are v3's measured ink, and the 2026-09-17
        // pass deliberately drew all three **larger** than this. That
        // departure is reverted, and the reason it can be is a palette
        // change rather than a change of mind: the old objection was that a
        // 1.35 pt track "in the *same grey as the ground*" was fainter than
        // the hairlines beside it — true when `well` was `ground` and a
        // track sat on a well of its own colour. v3 separates the two
        // (`surface.rail` #2d2d2c under `surface.control` #5f5f5f), so the
        // thin track now has the contrast the thick one was borrowing.
        //
        // **Ink only.** §3 of the handoff is explicit that hit regions stay
        // independent of it, so every one of these is drawn at the measured
        // size inside a padded target — see `ScrubSlider` and `CheckBox`.

        /// Track height, 2.71 / 2.
        static let trackHeight: CGFloat = 1.36
        /// The knob: v3's vector bounds, a dot rather than a handle.
        static let knobSize = CGSize(width: 6.13, height: 5.07)
        static let knobRadius: CGFloat = 2.535
        /// The checkbox's **drawn** square. Its hit target is padded to 16.
        static let checkbox: CGFloat = 5
        /// The hit target every one of the three sits inside, so that a 5 pt
        /// square and a 6 pt dot are still things a pointer can find.
        static let controlHitTarget: CGFloat = 16

        // MARK: glyphs

        /// A tool glyph on the bar. v3's bounds are zoom ≈21.3 × 21.6,
        /// Select ≈12.9 × 16.6, Pan ≈21.4 × 16.5, Crop ≈17.9 × 19.6 — not one
        /// square, which is §6's point: optical alignment beats stretching
        /// every silhouette to the same box. 16 sets an SF Symbol at about
        /// the middle of that range inside the 28 pt hit region.
        static let toolIcon: CGFloat = 16
        /// A rail header's glyph — import, export. §6 suggests 18.
        static let panelIcon: CGFloat = 18
        /// The reset arrow v3 adds to the Camera header: 8–9 pt of ink inside
        /// a 26 pt rail-action hit region.
        static let resetIcon: CGFloat = 9
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

        /// The zoom pill on the bar. v3 draws it x 2769.98…2852.56,
        /// y 17.63…59.01 → **41.29 × 20.69**: a third of the width it was,
        /// because v3's pill holds `100 %` and nothing else — the `Fit ·`
        /// prefix the old 105 pt pill carried does not fit and moves into the
        /// menu. It carries **no stroke**; it is a plain `.st13` capsule
        /// like every other pill.
        static let zoomPill = CGSize(width: 41.29, height: 20.69)

        static let minWindow = CGSize(width: 1100, height: 700)

        /// Card corner radius — the export page's old one (`rx 30 → 15`).
        ///
        /// **Nothing draws a card any more.** The editor stopped on
        /// 2026-09-17 and the export page followed; both are flush rails
        /// separated by hairlines, which is what each page's own drawing
        /// shows. Kept as the recorded value of a shape the interface no
        /// longer has, so that reinstating one is a decision rather than a
        /// guess at a radius.
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
            /// **Superseded.** The window-leading inset of the mode
            /// buttons while the bar was a full-width row; the bar is a pill
            /// over the centre column now and uses `barPadding`, as the
            /// editor's does. Kept as the drawing's recorded number.
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
    // ## Why this is four sizes and one weight
    //
    // The ramp this replaces had six sizes (12, 11.5, 10.5, 10, 9, 7) and
    // four weights scattered across eleven roles, with `listItem`, `label`,
    // `value` and `tab` all landing on 10.5 — four different jobs at one
    // size, told apart by weight alone. The result is what the user called
    // headers, labels, values, metadata and list items competing instead of
    // forming a hierarchy, and it is measurable:
    //
    //     metric                     drawing   that ramp
    //     ink-height spread            4.0 pt     7.0 pt
    //     stem-width spread            1.0 px     2.41 px
    //
    // The drawing is *tighter* than the interface was, not looser. It sets
    // nearly one size and one weight — its section title and its list rows
    // measure the same stem to a tenth of a pixel — and gets its hierarchy
    // from **colour, position and space**. Six sizes and four weights read as
    // noise, and no amount of it makes a rail legible.
    //
    // ## One weight, and why that is the fix rather than the problem
    //
    // "Too uniformly bold" reads like an instruction to unbold something, and
    // the first attempt at this ramp did exactly that — bold title, semibold
    // body, semibold meta. It made the measurement **worse**: stem spread
    // went from 2.41 px to 2.99 px against the drawing's 1.00.
    //
    // The drawing's stems are uniform because the drawing is set in one
    // weight — Illustrator exports it as `SFPro-Bold` on every text class it
    // has — and this app is SF Pro bold throughout by house style. A ramp
    // that mixes weights cannot be uniform, so mixing weights is the thing
    // that breaks it. The complaint is real and it is not about the face: it
    // is that eleven roles at one *size* in one *ink* have nothing left to
    // tell them apart.
    //
    // So the weight stays put and the other two axes do the work:
    //
    //     size   12.5 title · 11 body · 9.5 meta        (three, was six)
    //     ink    primary · secondary · tertiary          (see `Ink`)
    //
    // `mean stem width` is *not* a target to chase: Illustrator's rasteriser
    // lays down thinner stems than the macOS text system at the same nominal
    // weight, so the reference reads ~1 px light no matter what the app does.
    // The honest metric across the two is the **spread**, where that bias
    // cancels. Measured by `Tools/compare-design.swift`.

    // ## What v3 changed about the ramp above
    //
    // The three-size argument survives; the sizes do not. v3 measures the
    // two rails at **different** section-title sizes — 12 on the left, 10.5
    // on the right — and their control labels at different sizes too, 9 in
    // Camera against 10.5 in Film. That is not noise in the drawing: the
    // right rail is 288 pt wide and carries the longer names, and setting it
    // a step smaller is how the drawing fits `Color Balance` and
    // `White Balance` on one line without truncating. So `sectionTitle`
    // splits by rail, and so does `label`.
    //
    // The weight does not move. All SF Pro Bold, on the user's explicit
    // instruction (handoff §5) — the PDF's embedded `SFPro-Regular` name and
    // its weight-400 metadata are artefacts of the export and do not
    // override it.

    enum Font {
        /// A rail's own name — Develop, Edit.
        static let railTitle = SwiftUI.Font.system(size: 12, weight: .bold)
        /// A section title on the **left** rail: Input / Camera, Film, Print,
        /// Crop.
        static let leftSectionTitle = SwiftUI.Font.system(size: 12, weight: .bold)
        /// A section title on the **right** rail: Histogram, White Balance,
        /// Exposure, Curve, Color Balance. A step smaller, and that is the
        /// drawing rather than a compromise — see the note above.
        static let rightSectionTitle = SwiftUI.Font.system(size: 10.5, weight: .bold)
        /// The old single title role, kept pointing at the left rail's size
        /// so that anything not yet migrated — the Settings page, the export
        /// page's own `Export.sectionTitle` — keeps a title-sized title.
        static let sectionTitle = leftSectionTitle

        /// **The workhorse**, and v3 halves it into two.
        ///
        /// `body` is 10.5: Film's labels, the stock group eyebrows, the EDR
        /// row, the zoom readout. `small` is 9: Camera's labels, every
        /// control value, a stock row, "As Shot". They are not a hierarchy —
        /// a stock row is not subordinate to a Film label — they are two
        /// densities, and which one a row takes is a property of the block
        /// it is in.
        static let body = SwiftUI.Font.system(size: 10.5, weight: .bold)
        static let small = SwiftUI.Font.system(size: 9, weight: .bold)

        static let filmLabel = body
        static let stockGroup = body
        static let edrLabel = body
        static let zoomValue = SwiftUI.Font.system(size: 10.5, weight: .bold).monospacedDigit()

        static let cameraLabel = small
        static let listItem = small
        static let stockItem = small
        static let asShot = small
        /// Values keep monospaced digits — a number that changes under the
        /// pointer must not reflow the row it is in (preserved policy).
        static let value = SwiftUI.Font.system(size: 9, weight: .bold).monospacedDigit()
        static let pill = value

        /// `label` is the *shared* label role, and it is Film's: the wider of
        /// the two, so a row that has not been told which block it is in gets
        /// the readable one rather than the tight one. Camera passes
        /// `cameraLabel` explicitly.
        static let label = body
        static let tab = body

        /// Developed / Original, the two capsules under the print list. The
        /// largest type in the interface, and measured — v3 sets them at
        /// 26.22 / 2.
        static let action = SwiftUI.Font.system(size: 13.11, weight: .bold)

        /// Text that is *about* a control rather than part of it: a caption
        /// under a plot, a disabled reason. `Ink.tertiary` wherever it is
        /// used.
        static let meta = SwiftUI.Font.system(size: 9, weight: .bold)
        static let sublabel = meta
        static let groupHeader = stockGroup
        static let caption = meta

        /// The `CINE` badge. v3 sets it at 11.42 / 2 = **5.71** inside a
        /// 21.59 pt pill — very small, and §5 of the handoff flags it for
        /// optical QA rather than asserting it reads.
        static let cine = SwiftUI.Font.system(size: 5.71, weight: .bold)

        /// The export page's ramp is **the same ramp**.
        ///
        /// It used to be six roles at `.bold` — every string on the page in
        /// the heaviest face there is, which is the flattest hierarchy
        /// available and the reason the page read as a wall. The drawing does
        /// set `font-weight: 700` on its text classes, but a drawing sets one
        /// weight because an Illustrator artboard has no semibold; that is a
        /// fact about the export, not an instruction. The page's sizes were
        /// also its own (10.5 / 12 / 9 / 8), so the two pages disagreed about
        /// what a list row is. They agree now.
        /// **v3 froze this ramp rather than following the editor's.**
        ///
        /// It used to alias the editor's roles, which was right while there
        /// was one ramp. v3 re-sizes the editor's and specifies only the main
        /// editor (handoff §5 and §9: "Do not globally repoint
        /// `Font.Export`… Capture current export values before any later
        /// shared-token migration"). So these are the literal values the
        /// aliases resolved to at `eda971b` — 12.5 / 11 / 11 / 11 / 11 / 9.5
        /// — written out, so the export page holds still until its own
        /// drawing is translated.
        enum Export {
            static let sectionTitle = SwiftUI.Font.system(size: 12.5, weight: .bold)
            static let label = SwiftUI.Font.system(size: 11, weight: .bold)
            static let listItem = SwiftUI.Font.system(size: 11, weight: .bold)
            static let chip = SwiftUI.Font.system(size: 11, weight: .bold)
            static let value = SwiftUI.Font.system(size: 11, weight: .bold).monospacedDigit()
            static let pill = SwiftUI.Font.system(size: 9.5, weight: .bold)
        }
    }

    // MARK: ink
    //
    // The hierarchy the ramp above deliberately does not carry. One size of
    // type in three inks reads as three levels; three sizes of type in one
    // ink reads as a mess, which is what the rail was doing.

    enum Ink {
        /// A section title, a value, a selected list row — the thing being
        /// said.
        static let primary = text
        /// A control's label, an unselected list row — the thing being asked.
        static let secondary = secondaryText
        /// Metadata: "As Shot", captions, an inactive tab, a unit.
        static let tertiary = dim
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

/// The vertical member of the same wall.
///
/// **v3 runs it the full window height**, canvas included: its dividers are
/// at x 254.41 and x 1631.93 from the top edge to the bottom. The
/// 2026-09-17 rule — that only the filmstrip needs one, because between a
/// rail and the canvas the ground colour is already a separator — is
/// superseded. It stays an **overlay** at both call sites, so a line that is
/// 1 pt wide does not make the three-column arithmetic 2 pt wrong.
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
