//  DevelopLayout.swift — the develop page's arithmetic, apart from its views.
//
//  design/edit_v2 (`design/src/gen_edit_v2.py`): the tabs at each level, and where every part of every
//  panel sits. Kept apart from the views, with nothing of SwiftUI in it: **the panel is 220 pt and the
//  drawing uses nearly all of it** (pro's Print ends 2 pt above the actions), so
//  `tools/develop_selftest.swift` holds every panel's parts apart from each other and inside the panel,
//  from the numbers the views are placed by.

import CoreGraphics

// MARK: - the tabs

/// The stages, in the order a picture is made (the owner, 2026-10-08): the
/// film, its frame, the print, and what the materials add. Scene is
/// pro-control's: its controls reach a RAW file's decode and nothing else.
enum DevelopTab: String, CaseIterable, Identifiable, Sendable {
    case film, frame, print, scene, effects
    var id: String { rawValue }
    var title: String { L(shown: rawValue.prefix(1).uppercased() + rawValue.dropFirst()) }

    /// The tabs a level shows: four, and five under pro-control.
    static func shown(pro: Bool) -> [DevelopTab] { pro ? allCases : allCases.filter { $0 != .scene } }

    /// The tab the page stands on at a level: Scene goes with pro-control, and
    /// the page is then on the tab before it.
    func kept(pro: Bool) -> DevelopTab { !pro && self == .scene ? .print : self }
}

/// What Effects holds. Basic has the three strengths on one page and Scene
/// Placement on a page of its own; pro-control has a page an effect.
enum EffectsPage: String, CaseIterable, Identifiable, Sendable {
    case grain, halation, glare, couplers, placement
    var id: String { rawValue }
    var title: String { L(shown: rawValue.prefix(1).uppercased() + rawValue.dropFirst()) }

    /// Edit › EngineRouter's Effects tile (2026-10-22): pro-control's pills without
    /// Scene Placement, which is Decode's there.
    static let darkroom: [EffectsPage] = [.grain, .halation, .glare, .couplers]
}

/// The enlarger's three tools on Print, under pro-control. Basic has its colour.
enum EnlargerTool: String, CaseIterable, Identifiable, Sendable {
    case colour, brightness, preflash
    var id: String { rawValue }
    var title: String {
        switch self {
        case .colour: L("Colour")
        case .brightness: L("Brightness")
        case .preflash: L("Pre-flash")
        }
    }
}

/// What the enlarger's two filters do on the paper a frame is printed on, as
/// the Print tab says it: the word after each ruler's name, whether its scale
/// is tinted, and the name of pro-control's tool that holds the two.
///
/// On a colour paper they are a colour (`PrintPanel`'s scales, measured). **On
/// the silver paper they are its grade, and no colour at all** — measured
/// through the engine on 2026-10-09, on each of the four black-and-white films
/// (`Stock.swift`, `silver(_:into:)`; `rfc/audits/black-and-white-handoff-2026-10-09/probes/grade_shift.txt`):
/// Yellow +1 is a softer and darker print (Tri-Ex: the steepest 0.44 D a stop
/// becomes 0.33), Magenta +1 a harder and lighter one (0.62), neutral
/// throughout. The rulers keep their names, which are the enlarger's filters';
/// the word says where each takes the print, and the scale carries no tint,
/// as Brightness's has none. Not drawn (design/edit_v2 draws a colour print).
struct EnlargerScales: Equatable, Sendable {
    var yellow: String
    var magenta: String
    var tinted: Bool
    var tool: String

    static var colour: EnlargerScales { EnlargerScales(yellow: L("→ blue"), magenta: L("→ green"), tinted: true, tool: L("Colour")) }
    static var grade: EnlargerScales { EnlargerScales(yellow: L("→ softer"), magenta: L("→ harder"), tinted: false, tool: L("Grade")) }

    static func of(_ params: FilmParams, catalog: StockCatalog = .shared) -> EnlargerScales {
        catalog.isSilverPrint(params) ? .grade : .colour
    }
}

extension EnlargerTool {
    /// The tool's chip on a print: the two filters' tool is named for what
    /// they are there.
    func title(on scales: EnlargerScales) -> String { self == .colour ? scales.tool : title }
}

enum SceneTool: String, CaseIterable, Identifiable, Sendable {
    case whiteBalance, lens, placement
    var id: String { rawValue }
    /// The tools the Scene page offers. Lens correction is Settings' for the whole library since
    /// 2026-10-21 (the owner: "we put 'use lens correction' in settings, not edit"); its panel is
    /// kept, and offered nowhere.
    static let shown: [SceneTool] = [.whiteBalance]
    /// Edit › EngineRouter's Decode tile (2026-10-22): White Balance, and Scene Placement beside it —
    /// what is solved before the film, which edit_v2's pro-control had under Effects.
    static let decode: [SceneTool] = [.whiteBalance, .placement]
    var title: String {
        switch self {
        case .whiteBalance: L("White Balance")
        case .lens: L("Lens")
        case .placement: L("Scene Placement")
        }
    }
}

/// V5's Enlarger page, stacked (`PrintPanel.stacked`, 2026-10-20): the gaps
/// between its parts, each a measure the design system already uses, so the
/// page keeps Develop's rhythm and not a number of its own. Its height, under
/// the darkroom's 44 pt header, is 8 + 90 + 9 + 44 + 5 + 53 + 4 + 53 = 266 pt:
/// with the header, V5's 310 pt panel exactly.
enum EnlargerStack {
    /// Over the paper row: Develop's Film & Paper panel's own top.
    static let top: CGFloat = 8
    /// Card row to the enlarger's line, and a title over a note: a page's
    /// margin (`Theme.Metric.margin`; this file has nothing of SwiftUI).
    static let section: CGFloat = 16
    /// The tools' pills are Develop's shelf pills' height and type (`Chip`'s
    /// own 30 pt and 13 pt), a little narrower so three fit beside the label.
    static let chipHeight: CGFloat = 30
    static let chipPadding: CGFloat = 12
    static let chipSpacing: CGFloat = 6
    /// The pills' line to the first ruler's top: Develop's 10 between its rows, and the 2 a ruler's label leads by.
    static let afterTools: CGFloat = 12
    /// Between the two rulers, and a ruler and its note.
    static let rulerGap: CGFloat = 4
    static let noteGap: CGFloat = 4
}

// MARK: - the panels

/// The panel's own coordinates: y from the rule under the tabs (550 in the
/// drawings), so every number below is the generator's minus 550.
enum PanelY {
    static let height: CGFloat = 220

    /// A row's own measures (`gen_edit_v2.rrow`, `row`, `notes`).
    enum Part {
        /// A ruler's centre line under its label's baseline, and its half height.
        static let rulerDrop: CGFloat = 23
        static let rulerHalf: CGFloat = 16
        /// A 13.5 pt label's ink above its baseline (its capitals), and below (its descenders).
        static let labelAscent: CGFloat = 10
        static let labelDescent: CGFloat = 3.5
        /// A note's lines, baseline to baseline (11.5 pt × 1.42), and its ink.
        static let noteLead: CGFloat = 16.33
        static let noteAscent: CGFloat = 8.5
        static let noteDescent: CGFloat = 3
        /// The film, paper and size cards' selection frame, outside the card.
        static let cardFrame: CGFloat = 1.5
    }

    enum Film {
        static let cards: CGFloat = 14
        static let cardHeight: CGFloat = 96
        static let exposureLabel: CGFloat = 140
        static let dial: CGFloat = 154
        static let dialHeight: CGFloat = 40
        /// Pro: the meter's intent, a pill on the label's line.
        static let meterPill: CGFloat = 124.5
        static let meterPillHeight: CGFloat = 22
    }

    enum Frame {
        static let cards: CGFloat = 10
        static let cardHeight: CGFloat = 80
        static let note: CGFloat = 107
        /// Film Edge, Date Back, Crop: one line each.
        static let rows: [CGFloat] = [136, 168, 200]
        static let rowPitch: CGFloat = 32
        /// A row's separator under its baseline.
        static let separator: CGFloat = 12.5
    }

    enum Print {
        static let cards: CGFloat = 8
        static let cardHeight: CGFloat = 70
        /// Basic: ENLARGER, then Yellow and Magenta.
        static let label: CGFloat = 99
        static let yellow: CGFloat = 119
        static let magenta: CGFloat = 171
        /// On a half-frame pair (`gen_pair_v2.panel_print`): the pill a frame's
        /// print wears, its top; and the two rows, clear of it.
        static let pairPill: CGFloat = 84
        static let pairYellow: CGFloat = 122
        static let pairMagenta: CGFloat = 173
        /// Pro: the label and the three tools on one line, then the tool's rows.
        static let proLabel: CGFloat = 102
        static let chips: CGFloat = 86
        static let chipHeight: CGFloat = 24
        static let proFirst: CGFloat = 129
        static let proSecond: CGFloat = 179
        static let proNote: CGFloat = 180
        /// A slide film: its line, and the two under it.
        static let slideTitle: CGFloat = 110
        static let slideNote: CGFloat = 130
    }

    enum Effects {
        /// Basic: three strengths, a rule, and Scene Placement's row.
        static let strengths: [CGFloat] = [23, 79, 135]
        static let rule: CGFloat = 182.5
        static let placementRow: CGFloat = 202
        /// Scene Placement's own page: the way back, the rule, Highlight, the note.
        static let back: CGFloat = 27
        static let backRule: CGFloat = 44.5
        static let highlight: CGFloat = 74
        static let placementNote: CGFloat = 136
        /// Pro: the chips, then one ruler or two, then the note.
        static let chips: CGFloat = 12
        static let chipHeight: CGFloat = 28
        static let first: CGFloat = 68
        static let second: CGFloat = 120
        static let noteAfterOne: CGFloat = 128
        static let noteAfterTwo: CGFloat = 178
        /// Grain's Sub-layers: its label, and the switch's top.
        static let subLayers: CGFloat = 188
        static let subLayersSwitch: CGFloat = 168
        static let switchHeight: CGFloat = 31
    }

    enum Scene {
        static let chips: CGFloat = 12
        static let chipHeight: CGFloat = 28
        /// ↺, a disc of 32 at the row's trailing end.
        static let reset: CGFloat = 26
        static let resetRadius: CGFloat = 16
        static let first: CGFloat = 68
        static let second: CGFloat = 120
        static let note: CGFloat = 178
        /// Lens: its switch's top beside the label at `first`.
        static let lensSwitch: CGFloat = 48
        static let lensNote: CGFloat = 92
    }
}

/// The panels' quiet lines, as they are set: **one element is one line**. A
/// view sets each on a line of its own and never wraps it (`panelNote`), so a
/// note is as tall as its count here — which is what `PanelState` holds the
/// rest of its panel against — and `tools/develop_selftest.swift` measures
/// every line, with every stock's name in it, against the narrowest host.
enum PanelNotes {
    /// The size, in type no smaller than this of its own, a line is set at
    /// before it would be cut short.
    static let size: CGFloat = 11.5
    static let leastScale: CGFloat = 0.75

    /// Frame: whose the film's size is. `edge` is a film edge's own format.
    static func filmSize(edge: String?) -> [String] {
        if let edge { return [L("Film Edge sets the film's size: \(edge). Grain and halation follow.")] }
        return [L("The film's size. Grain and halation scale with it.")]
    }

    /// Print, under a slide film and under a negative that is scanned.
    static func slideTitle(_ film: String) -> String { L("\(film) is a slide.") }
    static var slide: [String] { [L("A slide is the picture itself: it is scanned, not printed."),
                                  L("Paper and the enlarger wait for a negative.")] }
    static var scannedTitle: String { L("Scanned, not printed.") }
    static var scanned: [String] { [L("This negative is read as the negative it is."), L("Choose a paper to print it.")] }

    /// Print under pro-control: the enlarger's other two tools.
    static var brightness: [String] { [L("The enlarger's exposure. It prints again from the same negative.")] }
    static var preflash: [String] { [L("A flash of plain light on the paper first: softer highlights.")] }

    /// Whether Scene's two controls reach a frame: they are a RAW file's
    /// decode, and reach nothing else.
    enum SceneReach: CaseIterable, Sendable {
        /// Developed from its RAW file.
        case raw
        /// A HEIF or a JPEG: its camera developed it.
        case notRAW
        /// A RAW the app has only a preview copy of, and no way back to its
        /// file. No frame of a library on disk is one since 2026-10-10: a RAW
        /// read in place from Photos is developed from its original, brought
        /// into the working copies (`Originals`).
        case previewCopy
        /// A frame of a half-frame pair, developed from its RAW file: the two
        /// controls are that photograph's own, in the pair and by itself.
        case rawInPair
        /// A frame of a pair that has left the library.
        case gone

        /// The two controls move something.
        var reaches: Bool { self == .raw || self == .rawInPair }
    }

    /// Scene: the two controls of a RAW file's decode, and what a frame they do not reach says.
    static func whiteBalance(_ reach: SceneReach) -> [String] {
        switch reach {
        case .raw: [L("The RAW file's white balance, before the film."), L("RAW files only.")]
        case .notRAW: [L("This frame is not a RAW file: its camera set its white balance."), L("These reach a RAW file's decode only.")]
        case .previewCopy: [L("This frame's RAW is in Photos: its preview copy is developed."), L("These reach a RAW file's decode only.")]
        case .rawInPair: [L("This frame's own white balance, before the film."), L("The photograph by itself changes with it.")]
        case .gone: [L("This frame is no longer in the library."), L("Replace or remove it under Frame.")]
        }
    }

    static func lens(_ reach: SceneReach) -> [String] {
        switch reach {
        case .raw: [L("The RAW file's own lens correction: distortion and vignetting."), L("RAW files only.")]
        case .notRAW: [L("This frame is not a RAW file: it has no lens correction to apply."), L("RAW files only.")]
        case .previewCopy: [L("This frame's RAW is in Photos: its preview copy is developed."), L("RAW files only.")]
        case .rawInPair: [L("This frame's own lens correction: distortion and vignetting."), L("The photograph by itself changes with it.")]
        case .gone: [L("This frame is no longer in the library."), L("Replace or remove it under Frame.")]
        }
    }

    /// Grain's Sub-layers, beside its name: what the switch holds. On a
    /// black-and-white film the grain is one layer whatever the frame says
    /// (`StockCatalog.silver`), and the switch stands down.
    static func subLayers(layered: Bool, filmIsLayered: Bool) -> String {
        layered && filmIsLayered ? L("three, as the film has") : L("one layer")
    }

    /// Effects under pro-control, a page an effect.
    static func grain(film: String, size: String) -> [String] {
        [L("The film's own grain, at the size \(size) gives it."), L("1.00× is \(film) as it is. 0 is none.")]
    }

    static var halation: [String] { [L("Light that passes through the film and comes back:"), L("the glow around bright points. 0 is none.")] }

    /// `paper` is nil where nothing is printed: a scan has no paper to veil.
    static func glare(paper: String?) -> [String] {
        guard let paper else { return [L("The paper's veil. Nothing is printed here: a scan has none.")] }
        return [L("The paper's veil: light spread across the print."), L("1.0× is \(paper)'s own. It prints again.")]
    }

    static func couplers(film: String) -> [String] {
        [L("How hard the film's layers hold each other back:"), L("its colour separation. 1.00× is \(film) as it is.")]
    }

    /// Scene Placement: Highlight alone on basic's page, both sides on pro's.
    static func placement(film: String, pro: Bool) -> [String] {
        pro ? [L("Each side is pulled into what \(film) holds."), L("A side with nothing to take is dimmed, and says why.")]
            : [L("Pulls the scene's brightest part into what \(film) holds."), L("The Latitude card shades what was pulled.")]
    }

    /// The Fit's own reason takes the placement note's place, and may wrap:
    /// it is the last thing in its panel, and is given no more lines than this.
    static let placementReasonLines = 3

    /// Every line there is, for a film, a paper and a size by those names.
    static func all(film: String, paper: String, size: String) -> [String] {
        var out = filmSize(edge: nil) + filmSize(edge: size) + [slideTitle(film)] + slide + [scannedTitle] + scanned
        out += brightness + preflash
        out += SceneReach.allCases.flatMap { whiteBalance($0) + lens($0) }
        out += grain(film: film, size: size) + halation + glare(paper: paper) + glare(paper: nil) + couplers(film: film)
        out += placement(film: film, pro: false) + placement(film: film, pro: true)
        return out
    }
}

/// One part of a panel, as the rows of ink it takes: for the check that no
/// part of a panel lies over another or leaves the panel.
struct PanelBlock: Equatable, Sendable {
    var name: String
    var top: CGFloat
    var bottom: CGFloat
    /// Parts that share a line on purpose (a label and the pill beside it)
    /// carry the same lane and are not held against each other.
    var lane: String? = nil

    static func label(_ name: String, _ baseline: CGFloat, lane: String? = nil) -> PanelBlock {
        PanelBlock(name: name, top: baseline - PanelY.Part.labelAscent, bottom: baseline + PanelY.Part.labelDescent, lane: lane)
    }

    /// A ruler under its label (`rrow`): the label's line, then the ruler.
    static func ruler(_ name: String, _ baseline: CGFloat) -> [PanelBlock] {
        [label(name, baseline),
         PanelBlock(name: name + "'s ruler", top: baseline + PanelY.Part.rulerDrop - PanelY.Part.rulerHalf,
                    bottom: baseline + PanelY.Part.rulerDrop + PanelY.Part.rulerHalf)]
    }

    static func note(_ name: String, _ baseline: CGFloat, lines: Int) -> PanelBlock {
        PanelBlock(name: name, top: baseline - PanelY.Part.noteAscent,
                   bottom: baseline + CGFloat(lines - 1) * PanelY.Part.noteLead + PanelY.Part.noteDescent)
    }

    static func cards(_ name: String, top: CGFloat, height: CGFloat) -> PanelBlock {
        PanelBlock(name: name, top: top - PanelY.Part.cardFrame, bottom: top + height + PanelY.Part.cardFrame)
    }

    static func box(_ name: String, top: CGFloat, height: CGFloat, lane: String? = nil) -> PanelBlock {
        PanelBlock(name: name, top: top, bottom: top + height, lane: lane)
    }
}

/// Every state a panel is drawn in, and the parts it then holds.
enum PanelState: Hashable, Sendable {
    case film(pro: Bool)
    case frame
    case print(pro: Bool, tool: EnlargerTool)
    case printSlide
    case effects
    case placement
    case effectsPro(EffectsPage)
    case scene(SceneTool)

    static var all: [PanelState] {
        [.film(pro: false), .film(pro: true), .frame, .print(pro: false, tool: .colour), .printSlide, .effects, .placement]
            + EnlargerTool.allCases.map { .print(pro: true, tool: $0) }
            + EffectsPage.allCases.map { .effectsPro($0) }
            + SceneTool.allCases.map { .scene($0) }
    }

    /// The tab this state is one of.
    var tab: DevelopTab {
        switch self {
        case .film: .film
        case .frame: .frame
        case .print, .printSlide: .print
        case .effects, .placement, .effectsPro: .effects
        case .scene: .scene
        }
    }

    var name: String {
        switch self {
        case .film(let pro): pro ? "Film, pro" : "Film"
        case .frame: "Frame"
        case .print(let pro, let tool): pro ? "Print, pro, \(tool.title)" : "Print"
        case .printSlide: "Print, a slide"
        case .effects: "Effects"
        case .placement: "Effects, Scene Placement"
        case .effectsPro(let page): "Effects, pro, \(page.title)"
        case .scene(let tool): "Scene, \(tool.title)"
        }
    }

    /// The names a note's line count is asked with: the count is the words', not the names'.
    private static let film = "the film", paper = "the paper", size = "135"
    /// Scene Placement's note at its tallest: the Fit's own reason, wrapped.
    private static func placementLines(pro: Bool) -> Int {
        max(PanelNotes.placement(film: film, pro: pro).count, PanelNotes.placementReasonLines)
    }

    var blocks: [PanelBlock] {
        typealias B = PanelBlock
        switch self {
        case .film(let pro):
            var out = [B.cards("the film cards", top: PanelY.Film.cards, height: PanelY.Film.cardHeight),
                       B.label("Film Exposure", PanelY.Film.exposureLabel, lane: "exposure"),
                       B.box("the dial", top: PanelY.Film.dial, height: PanelY.Film.dialHeight)]
            if pro {
                out.append(B.box("the meter's pill", top: PanelY.Film.meterPill, height: PanelY.Film.meterPillHeight, lane: "exposure"))
            }
            return out
        case .frame:
            return [B.cards("the size cards", top: PanelY.Frame.cards, height: PanelY.Frame.cardHeight),
                    B.note("the size's note", PanelY.Frame.note,
                           lines: max(PanelNotes.filmSize(edge: nil).count, PanelNotes.filmSize(edge: Self.size).count))]
                + zip(["Film Edge", "Date Back", "Crop"], PanelY.Frame.rows).map { B.label($0, $1) }
        case .print(let pro, let tool):
            var out = [B.cards("the paper cards", top: PanelY.Print.cards, height: PanelY.Print.cardHeight)]
            guard pro else {
                return out + [B.label("ENLARGER", PanelY.Print.label)]
                    + B.ruler("Yellow", PanelY.Print.yellow) + B.ruler("Magenta", PanelY.Print.magenta)
            }
            out.append(B.label("ENLARGER", PanelY.Print.proLabel, lane: "tools"))
            out.append(B.box("the enlarger's tools", top: PanelY.Print.chips, height: PanelY.Print.chipHeight, lane: "tools"))
            switch tool {
            case .colour:
                out += B.ruler("Yellow", PanelY.Print.proFirst) + B.ruler("Magenta", PanelY.Print.proSecond)
            case .brightness:
                out += B.ruler("Brightness", PanelY.Print.proFirst)
                    + [B.note("Brightness's note", PanelY.Print.proNote, lines: PanelNotes.brightness.count)]
            case .preflash:
                out += B.ruler("Pre-flash", PanelY.Print.proFirst)
                    + [B.note("Pre-flash's note", PanelY.Print.proNote, lines: PanelNotes.preflash.count)]
            }
            return out
        case .printSlide:
            return [B.cards("the paper cards", top: PanelY.Print.cards, height: PanelY.Print.cardHeight),
                    B.label("the slide's line", PanelY.Print.slideTitle),
                    B.note("the slide's note", PanelY.Print.slideNote, lines: max(PanelNotes.slide.count, PanelNotes.scanned.count))]
        case .effects:
            return zip(["Grain", "Halation", "Glare"], PanelY.Effects.strengths).flatMap { B.ruler($0, $1) }
                + [B.box("the rule", top: PanelY.Effects.rule, height: 1), B.label("Scene Placement", PanelY.Effects.placementRow)]
        case .placement:
            return [B.label("the way back", PanelY.Effects.back), B.box("the rule", top: PanelY.Effects.backRule, height: 1)]
                + B.ruler("Highlight", PanelY.Effects.highlight)
                + [B.note("Placement's note", PanelY.Effects.placementNote, lines: Self.placementLines(pro: false))]
        case .effectsPro(let page):
            var out = [B.box("the effects' chips", top: PanelY.Effects.chips, height: PanelY.Effects.chipHeight)]
            switch page {
            case .grain:
                out += B.ruler("Grain", PanelY.Effects.first)
                out.append(B.note("Grain's note", PanelY.Effects.noteAfterOne,
                                  lines: PanelNotes.grain(film: Self.film, size: Self.size).count))
                out.append(B.label("Sub-layers", PanelY.Effects.subLayers, lane: "sublayers"))
                out.append(B.box("the switch", top: PanelY.Effects.subLayersSwitch, height: PanelY.Effects.switchHeight, lane: "sublayers"))
            case .halation:
                out += B.ruler("Halation", PanelY.Effects.first) + B.ruler("Scatter", PanelY.Effects.second)
                out.append(B.note("Halation's note", PanelY.Effects.noteAfterTwo, lines: PanelNotes.halation.count))
            case .glare:
                out += B.ruler("Glare", PanelY.Effects.first)
                out.append(B.note("Glare's note", PanelY.Effects.noteAfterOne,
                                  lines: max(PanelNotes.glare(paper: Self.paper).count, PanelNotes.glare(paper: nil).count)))
            case .couplers:
                out += B.ruler("Couplers", PanelY.Effects.first)
                out.append(B.note("Couplers' note", PanelY.Effects.noteAfterOne, lines: PanelNotes.couplers(film: Self.film).count))
            case .placement:
                out += B.ruler("Highlight", PanelY.Effects.first) + B.ruler("Shadow", PanelY.Effects.second)
                out.append(B.note("Placement's note", PanelY.Effects.noteAfterTwo, lines: Self.placementLines(pro: true)))
            }
            return out
        case .scene(let tool):
            var out = [B.box("the scene's chips", top: PanelY.Scene.chips, height: PanelY.Scene.chipHeight, lane: "tools")]
            switch tool {
            case .whiteBalance:
                out.append(B.box("↺", top: PanelY.Scene.reset - PanelY.Scene.resetRadius, height: 2 * PanelY.Scene.resetRadius, lane: "tools"))
                out += B.ruler("Temperature", PanelY.Scene.first) + B.ruler("Tint", PanelY.Scene.second)
                out.append(B.note("White Balance's note", PanelY.Scene.note,
                                  lines: PanelNotes.SceneReach.allCases.map { PanelNotes.whiteBalance($0).count }.max() ?? 2))
            case .lens:
                out.append(B.label("Lens correction", PanelY.Scene.first, lane: "lens"))
                out.append(B.box("the switch", top: PanelY.Scene.lensSwitch, height: PanelY.Effects.switchHeight, lane: "lens"))
                out.append(B.note("Lens's note", PanelY.Scene.lensNote,
                                  lines: PanelNotes.SceneReach.allCases.map { PanelNotes.lens($0).count }.max() ?? 2))
            case .placement:
                // Edit › EngineRouter › Decode's second pill: pro-control's Scene Placement page, at the Scene page's rows.
                out += B.ruler("Highlight", PanelY.Scene.first) + B.ruler("Shadow", PanelY.Scene.second)
                out.append(B.note("Placement's note", PanelY.Scene.note, lines: Self.placementLines(pro: true)))
            }
            return out
        }
    }

    /// What is wrong with this panel as it is laid out: a part outside the
    /// panel, or two parts over each other. Empty when nothing is.
    func conflicts(height: CGFloat = PanelY.height, blocks given: [PanelBlock]? = nil) -> [String] {
        let parts = given ?? blocks
        var out: [String] = []
        for p in parts {
            if p.top < 0 { out.append("\(name): \(p.name) starts \(-p.top) pt above the panel") }
            if p.bottom > height { out.append("\(name): \(p.name) ends \(p.bottom - height) pt under the panel") }
        }
        for (i, a) in parts.enumerated() {
            for b in parts[(i + 1)...] where !(a.lane != nil && a.lane == b.lane) {
                if a.top < b.bottom && b.top < a.bottom {
                    out.append("\(name): \(a.name) (\(a.top)…\(a.bottom)) lies over \(b.name) (\(b.top)…\(b.bottom))")
                }
            }
        }
        return out
    }
}
