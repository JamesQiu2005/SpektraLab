//  AdjustInspector.swift — Edit's 调整: the strip of tiles, a tile's control, and its bar.
//
//  Litti's flow, drawn in the page's own parts (the owner's rule of
//  2026-10-16: a reference gives the flow, never the look):
//
//  - **The strip.** A row of tiles that scrolls sideways, each a rounded
//    square on the card colour with Apple's symbol for the control and its
//    name under it; a dot on a tile says it holds something. It sits at the
//    foot of the panel, over the page's own bar (↺ · ⋯ · Paste · Compare ·
//    Export), where the thumb is.
//  - **A tile's control** takes the strip's place, at the foot of the panel,
//    and **its bar takes the page's bar's place**: 🗑 puts the tool back to
//    rest at once (one step of the page's Undo, which is the ↶ beside it), its
//    name in the middle — a menu where the tool has two views (Tone, Curve) —
//    and ✓ goes back to the strip. Nothing is asked before 🗑: the ↶ next to
//    it takes it back, which a confirmation would only slow.
//  - The panel is as tall as what is open, and the picture above it takes the
//    rest, centred, so the status line and the band (调整 · 暗房 · 裁剪) sit
//    right on the tiles or the tool (the owner, 2026-10-19: "maximize the
//    image … whenever possible"). A tool is never taller than the page's
//    panel room (`height`). A tool of one line (Brightness, Contrast, Tone,
//    Vibrance, Saturation, Temperature, Vignette) is never shorter than the
//    strip it took the place of (the owner, 2026-10-22: "those with one line
//    edit bars is too narrow … should be the same … as the base adjust bar"):
//    opening and closing it does not move the picture.
//
//  Every control is live Layer 2 (`session.beganEdit/changeEdit/endedEdit`):
//  no develop, no job, the picture follows the finger.

import SwiftUI

/// What the open tool shows, kept for the page session: Tone's page, the
/// curve's view and channel, HSL's colour, the mixer's output, the picked pad.
struct AdjustState: Equatable {
    var tone: TonePage = .highlightsShadows
    var curveMode: CurveMode = .points
    var curveChannel: CurveChannel = .rgb
    var hue: HSLHue = .red
    var output: ChannelMixer.Channel = .red
    var zone: ColorBalance.Zone = .midtones
}

/// The panel: the strip, or the open tile's control.
struct AdjustInspector: View {
    let session: OpenFrameSession
    let height: CGFloat
    @Binding var state: AdjustState
    /// The tool takes the strip's place, so it keeps at least the strip's height. False where the
    /// tiles stay above it (the window's column): nothing moves there.
    var holdsStripHeight = true
    private var tool: AdjustTool? { session.pageNavigation.adjust }

    var body: some View {
        // Only as tall as what it shows: the page puts the spare room above
        // its band, so the band sits on the tiles. `height` is the most a
        // tool may take.
        VStack(spacing: 0) {
            if let tool {
                control(tool)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .frame(minHeight: holdsStripHeight ? min(AdjustStrip.rowHeight, height) : nil)
                    .transition(.opacity)
            } else {
                // A sideways scroll view takes all the height it is offered: held to its tiles'.
                AdjustStrip(session: session)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, AdjustStrip.rowInset)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder private func control(_ tool: AdjustTool) -> some View {
        switch tool {
        case .hsl: HSLTool(session: session, hue: $state.hue)
        case .channel: ChannelMixerTool(session: session, output: $state.output)
        case .wheels: ColourWheelsTool(session: session, height: height, zone: $state.zone)
        case .curve: CurveTool(session: session, height: height - 10, channel: $state.curveChannel, mode: state.curveMode)
        default: AdjustSliders(session: session, tool: tool, tone: state.tone)
        }
    }
}

/// The row of tiles; or, where the page has the room (a wide window's column, the owner 2026-10-21:
/// "不需要滚动展开，而是直接整体用矩阵的形式铺开"), every tile at once in a matrix.
struct AdjustStrip: View {
    let session: OpenFrameSession
    /// Tiles across a matrix; nil is the row that scrolls.
    var columns: Int? = nil

    /// A tile's width and height: the 60 pt square, 6 pt, its one line of name.
    static let tileWidth: CGFloat = 70
    static let tileHeight: CGFloat = 80
    /// The strip in the panel: one row of tiles, `rowInset` above and below it.
    static let rowInset: CGFloat = 12
    static var rowHeight: CGFloat { tileHeight + 2 * rowInset }
    private static let spacing: CGFloat = 10
    private static let rowSpacing: CGFloat = 14

    /// How many tiles go across `width`, its 16 pt margins taken off.
    static func columns(in width: CGFloat) -> Int {
        max(Int((width - 32 + spacing) / (tileWidth + spacing)), 1)
    }
    /// The matrix's height, `columns` across.
    static func matrixHeight(columns: Int) -> CGFloat {
        let rows = (AdjustTool.allCases.count + columns - 1) / max(columns, 1)
        return CGFloat(rows) * tileHeight + CGFloat(max(rows - 1, 0)) * rowSpacing
    }

    var body: some View {
        if let columns {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top),
                                     count: columns),
                      spacing: Self.rowSpacing) {
                ForEach(AdjustTool.allCases) { tool in tile(tool) }
            }
            .padding(.horizontal, 16)
            .accessibilityIdentifier("adjust.strip")
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(AdjustTool.allCases) { tool in tile(tool) }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("adjust.strip")
        }
    }

    private func tile(_ tool: AdjustTool) -> some View {
        // Where the tiles stay over the open tool (a wide window's column), the open one wears the white frame.
        EditTile(title: tool.title, symbol: tool.symbol, moved: !tool.isNeutral(in: session.adjustments),
                 open: session.pageNavigation.adjust == tool, identifier: "adjust.tile.\(tool.rawValue)") {
            session.pageNavigation.open(tool)
        }
    }
}

/// A tile of an Edit strip: Adjust's, and since 2026-10-22 EngineRouter's (the owner: "The way 暗房 is
/// arranged is officially gonna be the same as that in 调整"). A rounded square on the card colour
/// with Apple's symbol, its name under it, the accent dot while it holds something, the white frame
/// while it is open beside the tiles (a wide window's column).
struct EditTile: View {
    let title: String
    let symbol: String
    let moved: Bool
    let open: Bool
    let identifier: String
    /// What VoiceOver reads after the name: "Edited" unless the tile says more.
    var value: String? = nil
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var calm

    var body: some View {
        Button {
            withAnimation(calm ? nil : .easeOut(duration: 0.18)) { action() }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Theme.text)
                    .frame(width: 60, height: 60)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                    .overlay(alignment: .topTrailing) {
                        if moved { Circle().fill(Theme.accent).frame(width: 6, height: 6).padding(7) }
                    }
                    .overlay {
                        if open { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.selectionFrame, lineWidth: 2) }
                    }
                Text(title)
                    .font(Theme.Font.ui(11.5, .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(width: AdjustStrip.tileWidth)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(title)
        .accessibilityValue(value ?? (moved ? L("Edited") : ""))
        .accessibilityAddTraits(open ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// The open tile's bar, in the page's bar's place: 🗑 · ↶ · its name (or its menu) · ✓.
struct AdjustToolBar: View {
    let session: OpenFrameSession
    let tool: AdjustTool
    @Binding var state: AdjustState
    private var atRest: Bool { tool.isAtRest(in: session.adjustments) }

    var body: some View {
        EditToolBar(session: session, title: tool.title, atRest: atRest, identifier: "adjust",
                    reset: { session.changeEdit { tool.reset(&$0) } },
                    done: { session.pageNavigation.closeAdjust() }) { centre }
    }

    @ViewBuilder private var centre: some View {
        switch tool {
        case .tone:
            menu(state.tone.title) {
                Picker(L("Tone"), selection: $state.tone) { ForEach(TonePage.allCases) { Text($0.title).tag($0) } }
            }
        case .curve:
            menu(state.curveMode.title) {
                Picker(L("Curve"), selection: $state.curveMode) { ForEach(CurveMode.allCases) { Text($0.title).tag($0) } }
            }
        default:
            Text(tool.title).font(Theme.Font.ui(15, .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func menu<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) {
            HStack(spacing: 6) {
                Text(title).font(Theme.Font.ui(13.5, .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Theme.card, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(tool.title)
        .accessibilityValue(title)
        .accessibilityIdentifier("adjust.bar.menu")
    }
}

/// An open tile's bar, Adjust's and EngineRouter's: 🗑 the tile back to rest at once — one step of the
/// page's Undo, which is the ↶ beside it, so nothing is asked first — · ↶ · `centre` (its name, or
/// a menu) · ✓ back to the strip. `identifier` names its buttons: `<identifier>.bar.reset`, ….
struct EditToolBar<Centre: View>: View {
    let session: OpenFrameSession
    let title: String
    let atRest: Bool
    let identifier: String
    let reset: () -> Void
    let done: () -> Void
    @ViewBuilder let centre: () -> Centre
    @Environment(\.accessibilityReduceMotion) private var calm

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Button {
                    reset()
                } label: { disc("trash").opacity(atRest ? Theme.disabledOpacity : 1) }
                .disabled(atRest)
                .accessibilityLabel(L("Reset") + " " + title)
                .accessibilityIdentifier("\(identifier).bar.reset")
                Button { session.undo() } label: { disc("arrow.uturn.backward").opacity(session.canUndo ? 1 : Theme.disabledOpacity) }
                    .disabled(!session.canUndo)
                    .accessibilityLabel(L("Undo"))
                    .accessibilityIdentifier("\(identifier).bar.undo")
                Spacer(minLength: 0)
                Button {
                    withAnimation(calm ? nil : .easeOut(duration: 0.18)) { done() }
                } label: {
                    Image(systemName: "checkmark").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.onSelection)
                        .frame(width: 44, height: 44)
                        .background(Theme.selection, in: Circle())
                }
                .accessibilityLabel(L("Done"))
                .accessibilityIdentifier("\(identifier).bar.done")
            }
            centre().frame(maxWidth: 150)
        }
        .buttonStyle(PressStyle())
        .padding(.horizontal, 16)
        .macPageActions(confirm: done, cancel: done)
    }

    private func disc(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 18))
            .foregroundStyle(Theme.text)
            .frame(width: 44, height: 44)
            .background(Theme.card, in: Circle())
    }
}
