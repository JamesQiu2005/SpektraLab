//  MacLightTableBar.swift — the Mac Light Table's controls, floating over the table (2026-10-24; 2026-10-26).
//
//  The owner, 2026-10-24: "move the current bottom controls to the top right of the window, and include a
//  拖动 (drag) and 点击 (click) difference" — the website's toolbar, [拖动 | 点击] · 放大镜 · [− 适合窗口 +] · 分享.
//  And 2026-10-26: "the loupe page should be re-designed, mostly the top edits, that wraps like this [the
//  Develop bar]; loupe is the only page that could have the appearance of all control assets floating over
//  the base canvas, with rounded rectangle style, and simple Gaussian blur with clear rounded rectangle
//  boundaries." So the table fills the window and the controls stand on panels over it
//  (`MacLightTablePanel.swift`: the blur, the boundary, the develop-point drawing):
//
//  - **the title panel**, top left: ‹ the page under it, *Light Table*, and the status line (`dim`: "3 films ·
//    A4", a chosen film's "stock · format · size · angle"), the longest of its candidates that fits whole,
//    then the Undo pill for 6 s after a take-off or a rearrangement.
//  - **the tools panel**, top right, the develop bar's 36 pt discs (`Disc`, `Theme.Metric.barRound`, 8 pt
//    apart, drawn in the develop page's points so they are its size at every interface scale):
//    - **[Drag | Click]** (D, C): how the pointer moves a film. *Drag* is the table as it was: press a film
//      and move it, a click chooses it and brings it to the top, a double click zooms. *Click* is the
//      website's: a click picks a film up and it follows the pointer, a click puts it down (Esc puts it back
//      where it was), a drag from just outside a corner turns it freely (⇧: 15° steps), two fingers turning
//      on a trackpad turn the film under them. Either way the empty table pans when zoomed, the wheel zooms.
//    - **Loupe** (L): the lens follows the pointer over the table.
//    - **[− Fit +]** (−, 0, =): the zoom; the middle reads *Fit* or the zoom ("2.5×").
//    - **1:1** (1): Actual Size, the table at its real millimetres on this display (`MacDisplay`); greyed on
//      a display that does not know its size.
//    - **[A4 ▾ | ⟲]**: the table's size (each with its millimetres, the way it is turned, and the two ways up
//      under them) and one click to turn it.
//    - **···**: Tidy Up, Random, Scatter, Take All Off.
//    - **the rail** (⌥⌘0): the films on the table, in their own panel at the right, shown or put away.
//    - **Share**, the accent capsule, last, as Export ends the develop bar: Poster or Contact Sheet, then the
//      system's sheet.
//
//  A narrow window gives way in the owner's order (no "…", ever): first the words beside Drag, Click and
//  Loupe go, then the zoom and the table's size fold into ···, and only then does the status line take a
//  shorter candidate (`MacLightTableFloatRow`).

import SwiftUI

/// How the pointer moves a film (the website's tools, `setTool`).
enum MacLightTableTool: String, CaseIterable, Sendable {
    case drag = "drag", click = "click"

    var title: String { self == .drag ? L("Drag") : L("Click") }
    var symbol: String { self == .drag ? "arrow.up.and.down.and.arrow.left.and.right" : "cursorarrow.click" }
    var help: String {
        self == .drag ? L("Drag a film to move it") + " (D)" : L("Click a film to pick it up, and click again to put it down") + " (C)"
    }
}

/// What the controls do: the page's own functions.
struct MacLightTableActions {
    var back: () -> Void
    var setTool: (MacLightTableTool) -> Void
    var toggleLoupe: () -> Void
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var fit: () -> Void
    var actualSize: () -> Void
    var setTable: (LightTablePaper?, Bool?) -> Void
    var tidyUp: () -> Void
    var random: () -> Void
    var scatter: () -> Void
    var takeAllOff: () -> Void
    var share: () -> Void
    var toggleRail: () -> Void
    var undo: () -> Void
    var add: () -> Void
}

/// The panels' sizes, in the develop page's points (`MacDevelopPoints` draws them `factor` times larger).
enum MacLightTableFloat {
    /// The develop bar's disc.
    static var disc: CGFloat { Theme.Metric.barRound }
    /// Between two discs, as on the develop bar.
    static let spacing: CGFloat = 8
    /// A panel's padding around its discs: a panel is a disc and this above and below it.
    static let inset: CGFloat = 6
    static var band: CGFloat { disc + 2 * inset }
    /// From the window's edges, and between panels.
    static let gap: CGFloat = 12
    /// Below a windowed window's title bar (the page starts under it, `WindowShape.safeTop`): the title bar
    /// is a margin already, as the develop bar takes none of its own there.
    static let gapUnderTitleBar: CGFloat = 4
    static let radius: CGFloat = 14
    static let railRadius: CGFloat = 16
}

// MARK: - the title panel

struct MacLightTableTitlePanel: View {
    let backTitle: String
    /// The status line's candidates, longest first.
    let status: [String]
    let sharing: Bool
    let undoShown: Bool
    let back: () -> Void
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: back) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(Theme.Font.ui(15, .semibold))
                    Text(backTitle).font(Theme.Font.ui(15, .medium)).fixedSize()
                }
                .foregroundStyle(Theme.secondaryText)
                .frame(height: MacLightTableFloat.disc).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(backTitle)
            Text(L("Light Table")).font(Theme.Font.ui(15, .semibold)).foregroundStyle(Theme.text)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                ForEach(Array((status + [""]).enumerated()), id: \.offset) { _, line in
                    if line.isEmpty { Color.clear.frame(width: 0, height: 0) }
                    else { StatusLine(text: line, busy: sharing).lineLimit(1).fixedSize() }
                }
            }
            .accessibilityIdentifier("lighttable.status")
            if undoShown {
                Button(action: undo) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward").font(Theme.Font.ui(12, .semibold))
                        Text(L("Undo")).font(Theme.Font.ui(13, .medium))
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background(Theme.card, in: Capsule())
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("lighttable.undo")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: MacLightTableFloat.band)
    }
}

// MARK: - the tools panel

struct MacLightTableToolsPanel: View {
    let table: LightTableController
    let tool: MacLightTableTool
    let loupe: Bool
    let railShown: Bool
    let sharing: Bool
    let actions: MacLightTableActions

    /// How much of the panel a window has room for, widest first.
    enum Form: CaseIterable { case words, symbols, folded }

    private var disc: CGFloat { MacLightTableFloat.disc }
    private var empty: Bool { table.model.order.isEmpty }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Form.allCases, id: \.self) { form in tools(form) }
        }
    }

    private func tools(_ form: Form) -> some View {
        HStack(spacing: MacLightTableFloat.spacing) {
            if form == .words {
                // Drag and Click with their words, one capsule the disc's height, the lit one white.
                HStack(spacing: 0) {
                    ForEach(MacLightTableTool.allCases, id: \.self) { t in
                        segment(on: tool == t && !loupe, help: t.help, label: t.title, action: { actions.setTool(t) }) {
                            Image(systemName: t.symbol).font(.system(size: Disc<Image>.symbolSize(disc) - 2))
                            Text(t.title).font(Theme.Font.ui(14, .medium)).fixedSize()
                        }
                        .accessibilityIdentifier("lighttable.tool.\(t.rawValue)")
                    }
                }
                .background(Theme.card, in: Capsule())
                segment(on: loupe, help: Self.loupeHelp, label: L("Loupe"), action: actions.toggleLoupe) {
                    DrawnGlyph(icon: .standLoupe, size: 18, color: loupe ? Theme.onSelection : Theme.text,
                               ground: loupe ? Theme.selection : Theme.card)
                    Text(L("Loupe")).font(Theme.Font.ui(14, .medium)).fixedSize()
                }
                .background(Theme.card, in: Capsule())
                .disabled(empty)
                .accessibilityIdentifier("lighttable.loupe")
            } else {
                ForEach(MacLightTableTool.allCases, id: \.self) { t in
                    toolDisc(on: tool == t && !loupe, help: t.help, label: t.title, action: { actions.setTool(t) }) {
                        Image(systemName: t.symbol).font(.system(size: Disc<Image>.symbolSize(disc)))
                    }
                    .accessibilityIdentifier("lighttable.tool.\(t.rawValue)")
                }
                toolDisc(on: loupe, help: Self.loupeHelp, label: L("Loupe"), action: actions.toggleLoupe) {
                    DrawnGlyph(icon: .standLoupe, size: 18, color: loupe ? Theme.onSelection : Theme.text,
                               ground: loupe ? Theme.selection : Theme.card)
                }
                .disabled(empty)
                .accessibilityIdentifier("lighttable.loupe")
            }
            if form != .folded { zoomGroup }
            toolDisc(on: table.isActualSize, help: L("Actual Size") + " (1)", label: L("Actual Size"), action: actions.actualSize) {
                Text("1:1").font(Theme.Font.ui(14, .semibold)).fixedSize()
            }
            .disabled(table.pointsPerMM == nil)
            .accessibilityIdentifier("lighttable.actual-size")
            if form != .folded { sizeGroup }
            moreMenu(folded: form == .folded)
            toolDisc(on: railShown, help: L("Films on the Table") + " (⌥⌘0)", label: L("Films on the Table"), action: actions.toggleRail) {
                Image(systemName: "sidebar.right").font(.system(size: Disc<Image>.symbolSize(disc)))
            }
            .accessibilityIdentifier("lighttable.rail-toggle")
            // As Export ends the develop bar: the accent capsule, its height and width, 4 pt further off.
            CapsuleButton(title: L("Share"), height: disc, width: 112, enabled: !(empty || sharing)) { actions.share() }
                .help(L("Make a picture of the table to share"))
                .accessibilityIdentifier("lighttable.share")
                .padding(.leading, 4)
        }
        .fixedSize()
        .padding(MacLightTableFloat.inset)
    }

    private static var loupeHelp: String { L("Magnify what is under the pointer") + " (L)" }

    /// "Fit", or the zoom as it is: "2.5×".
    private var zoomWords: String {
        let z = table.viewport.zoom
        if !table.isActualSize && z < 1.01 && z > 0.99 { return L("Fit", as: "the window") }
        return LightTablePane.times(z)
    }
    private var canZoomOut: Bool { table.viewport.zoom > table.viewport.zoomFloor + 0.005 }
    private var canZoomIn: Bool { table.viewport.zoom < table.viewport.zoomCeiling - 0.005 }

    /// [− Fit +]: one capsule the disc's height.
    private var zoomGroup: some View {
        HStack(spacing: 0) {
            segment(on: false, help: L("Zoom Out") + " (−)", label: L("Zoom Out"), action: actions.zoomOut) {
                Image(systemName: "minus").font(Theme.Font.ui(14, .semibold))
            }
            .disabled(!canZoomOut)
            segment(on: false, help: L("Fit the table to the window") + " (0)", label: L("Fit"), action: actions.fit) {
                Text(zoomWords).font(Theme.Font.ui(14, .medium)).monospacedDigit().fixedSize()
                    .frame(minWidth: 34)
            }
            .accessibilityIdentifier("lighttable.fit")
            segment(on: false, help: L("Zoom In") + " (=)", label: L("Zoom In"), action: actions.zoomIn) {
                Image(systemName: "plus").font(Theme.Font.ui(14, .semibold))
            }
            .disabled(!canZoomIn)
        }
        .background(Theme.card, in: Capsule())
    }

    /// [A4 ▾ | ⟲]: one capsule the disc's height.
    private var sizeGroup: some View {
        HStack(spacing: 0) {
            Menu { sizePickers } label: {
                HStack(spacing: 4) {
                    Text(table.model.paper.name).font(Theme.Font.ui(14, .semibold)).fixedSize()
                    Image(systemName: "chevron.down").font(Theme.Font.ui(9, .bold)).foregroundStyle(Theme.dim)
                }
                .foregroundStyle(Theme.text)
                .padding(.leading, 14).padding(.trailing, 8)
                .frame(height: disc)
                .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Table Size"))
            .accessibilityLabel(L("Table Size"))
            .accessibilityValue(table.model.paper.name)
            .accessibilityIdentifier("lighttable.size")
            segment(on: false, help: L("Table Orientation"), label: L("Table Orientation"),
                    action: { actions.setTable(nil, !table.model.portrait) }) {
                Image(systemName: table.model.portrait ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                    .font(.system(size: Disc<Image>.symbolSize(disc) - 2))
            }
            .accessibilityValue(table.model.portrait ? L("Portrait") : L("Landscape"))
            .accessibilityIdentifier("lighttable.orientation")
        }
        .background(Theme.card, in: Capsule())
    }

    @ViewBuilder private var sizePickers: some View {
        Picker(L("Table Size"), selection: Binding(get: { table.model.paper }, set: { actions.setTable($0, nil) })) {
            ForEach(LightTablePaper.allCases) { p in
                let h = LightTable.half(p, portrait: table.model.portrait)
                Text(p.name + Fmt.dot + LightTablePane.sizeText(CGSize(width: 2 * h.width, height: 2 * h.height))).tag(p)
            }
        }
        .pickerStyle(.inline)
        Picker(L("Table Orientation"), selection: Binding(get: { table.model.portrait }, set: { actions.setTable(nil, $0) })) {
            Text(L("Portrait")).tag(true)
            Text(L("Landscape")).tag(false)
        }
        .pickerStyle(.inline)
    }

    /// ···: Tidy Up, Random, Scatter, Take All Off; and, folded, the zoom and the table's size before them.
    private func moreMenu(folded: Bool) -> some View {
        Menu {
            if folded {
                Button(action: actions.zoomIn) { Label(L("Zoom In"), systemImage: "plus.magnifyingglass") }
                    .disabled(!canZoomIn)
                Button(action: actions.zoomOut) { Label(L("Zoom Out"), systemImage: "minus.magnifyingglass") }
                    .disabled(!canZoomOut)
                Button(action: actions.fit) { Label(L("Fit the table to the window"), systemImage: "arrow.down.right.and.arrow.up.left") }
                Divider()
                Menu(L("Table Size")) { sizePickers }
                Divider()
            }
            Group {
                Button(action: actions.tidyUp) { Label(L("Tidy Up"), systemImage: "square.grid.2x2") }
                Button(action: actions.random) { Label(L("Random"), systemImage: "dice") }
                Button(action: actions.scatter) { Label(L("Scatter", as: "the films"), systemImage: "shuffle") }
                Divider()
                Button(role: .destructive, action: actions.takeAllOff) { Label(L("Take All Off"), systemImage: "minus.circle") }
            }
            .disabled(empty)
        } label: {
            Disc(diameter: disc) {
                Image(systemName: "ellipsis").font(.system(size: Disc<Image>.symbolSize(disc)))
            }
            .contentShape(Circle())
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(empty && !folded)
        .opacity(empty && !folded ? Theme.disabledOpacity : 1)
        .help(L("More"))
        .accessibilityLabel(L("More"))
        .accessibilityIdentifier("lighttable.more")
    }

    /// One tool on its own disc (`Disc`, the develop bar's): lit white while it is on, as the Light Table's
    /// tools have always been lit (the window's Loupe and 1:1 too).
    private func toolDisc<Glyph: View>(on: Bool, help: String, label: String, action: @escaping () -> Void,
                                   @ViewBuilder glyph: @escaping () -> Glyph) -> some View {
        Button(action: action) {
            Disc(diameter: disc, lit: on ? Theme.selection : nil, glyph: glyph).contentShape(Circle())
        }
        .buttonStyle(MacFloatPress())
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// One control of a capsule: lit white when on, as wide as its content and at least a disc.
    private func segment<Content: View>(on: Bool, help: String, label: String, action: @escaping () -> Void,
                                        @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { content() }
                .foregroundStyle(on ? Theme.onSelection : Theme.text)
                .padding(.horizontal, 12)
                .frame(minWidth: disc)
                .frame(height: disc)
                .background(on ? Theme.selection : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(MacFloatPress())
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A control pressed: a little dimmer; greyed when it cannot be used.
private struct MacFloatPress: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : Theme.disabledOpacity)
    }
}

/// The title panel and the tools panel along the window's top: the tools take what the title leaves at its
/// longest, in the widest form that fits (words, symbols, folded); only when even the folded tools do not fit
/// beside it does the title's status line take a shorter candidate. The owner's order for a narrow window.
struct MacLightTableFloatRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? (subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width } + spacing)
        let h = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let title = subviews[0], tools = subviews[1]
        let titleWhole = title.sizeThatFits(.unspecified).width
        let toolsLeast = tools.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
        let titleWidth = max(0, min(titleWhole, bounds.width - spacing - toolsLeast))
        let titleSize = title.sizeThatFits(ProposedViewSize(width: titleWidth, height: nil))
        let toolsRoom = max(0, bounds.width - spacing - titleSize.width)
        let toolsSize = tools.sizeThatFits(ProposedViewSize(width: toolsRoom, height: nil))
        title.place(at: bounds.origin, proposal: ProposedViewSize(titleSize))
        tools.place(at: CGPoint(x: bounds.maxX - toolsSize.width, y: bounds.minY), proposal: ProposedViewSize(toolsSize))
    }
}
