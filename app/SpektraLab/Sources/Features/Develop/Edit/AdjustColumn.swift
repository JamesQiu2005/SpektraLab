//  AdjustColumn.swift — Edit › Adjust in the Mac's column (the owner, 2026-11-11: "for screen space optimization,
//  these pills should be smaller, and user can now open multiple edit pills together, and are draggable to
//  re-arrange the position … the panel itself should also scroll … the client should also remember the layout").
//
//  Redrawn the same day after the owner found the pills-and-drag version "not intuitive": one list, the way
//  Capture One's and Lightroom's tool panels are.
//
//  - **Every tool is a folding section**, in one list: a click on its header unfolds it or folds it away; any
//    number are open at once. The header is slim (32 pt): chevron, symbol, name (a menu of its two views while
//    open: Tone, Curve), the accent dot while it holds something, Temperature's neutral-grey eyedropper while open,
//    ↺ while edited, and the grip. No pills above to open them from: the list is both.
//  - **Moving a tool** is dragging its header up or down: the section lifts and follows the pointer, and the
//    others step round it as it passes half of each — the order is what is seen while dragging, nothing to aim
//    at. Move Up / Move Down are in its context menu. The whole column scrolls.
//  - **Remembered** (`AdjustLayout`): the order and which tools are open, across launches, in the app's
//    defaults — the layout of the column, never a frame's edit.
//
//  The host's narrow page keeps its strip and one tool at a time (`AdjustInspector`).

import SwiftUI

/// The column's layout, kept across launches: the tools' order and which are open.
@MainActor @Observable
final class AdjustLayout {
    static let shared = AdjustLayout()

    @ObservationIgnored private let defaults: UserDefaults
    static let orderKey = "edit.adjust.order"
    static let openKey = "edit.adjust.open"

    /// Every tool, in the pills' and the sections' order.
    private(set) var order: [AdjustTool]
    /// The tools open, in no order of their own: they are shown in `order`'s.
    private(set) var open: Set<AdjustTool>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Leniently: a tool this build does not know is dropped (the vignette's own tile, gone into Lens on
        // 2026-11-11), one the defaults do not name keeps its place at the end.
        order = AdjustTool.order(from: defaults.stringArray(forKey: Self.orderKey) ?? [])
        open = Set((defaults.stringArray(forKey: Self.openKey) ?? []).compactMap(AdjustTool.init(rawValue:)))
    }

    /// The open tools, in order.
    var shownOpen: [AdjustTool] { order.filter(open.contains) }
    func isOpen(_ t: AdjustTool) -> Bool { open.contains(t) }

    func toggle(_ t: AdjustTool) {
        if open.contains(t) { open.remove(t) } else { open.insert(t) }
        save()
    }

    func show(_ t: AdjustTool) {
        guard !open.contains(t) else { return }
        open.insert(t)
        save()
    }

    /// `t` dropped on `target`: it takes that one's place.
    func move(_ t: AdjustTool, before target: AdjustTool) {
        guard t != target, let from = order.firstIndex(of: t), let to = order.firstIndex(of: target) else { return }
        #if DEBUG
        NSLog("[adjust] move %@ before %@", t.rawValue, target.rawValue)
        #endif
        order.remove(at: from)
        order.insert(t, at: from < to ? to - 1 : to)
        save()
    }

    /// One place earlier (−1) or later (+1).
    func shift(_ t: AdjustTool, by step: Int) {
        guard let from = order.firstIndex(of: t), order.indices.contains(from + step) else { return }
        order.swapAt(from, from + step)
        save()
    }

    private func save() {
        defaults.set(order.map(\.rawValue), forKey: Self.orderKey)
        defaults.set(AdjustTool.allCases.filter(open.contains).map(\.rawValue), forKey: Self.openKey)
    }
}

/// Edit › Adjust in the column: every tool as a folding section, in the column's order, scrolling as one.
struct AdjustColumn: View {
    let session: OpenFrameSession
    @Binding var state: AdjustState
    private var layout: AdjustLayout { .shared }

    /// The section being dragged, and how far its layout place has moved under the pointer so far (the heights
    /// of the sections it has passed): its offset is the drag's travel less that.
    @State private var dragging: AdjustTool?
    @State private var passed: CGFloat = 0
    @State private var travel: CGFloat = 0
    /// Each section's height now, for when the dragged one has passed half of its neighbour.
    @State private var heights: [AdjustTool: CGFloat] = [:]

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(layout.order) { t in
                        section(t)
                            .id(t)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { heights[t] = $0 }
                            .offset(y: dragging == t ? travel - passed : 0)
                            .zIndex(dragging == t ? 1 : 0)
                    }
                    Rectangle().fill(Theme.rule).frame(height: 0.5)
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
            // A tool asked open from elsewhere (the page's navigation, the driver): open here, and in view.
            .onChange(of: session.pageNavigation.adjust, initial: true) { _, asked in
                guard let asked else { return }
                layout.show(asked)
                session.pageNavigation.closeAdjust()
                scroll(to: asked, reader)
            }
        }
        .accessibilityIdentifier("adjust.column")
    }

    private func section(_ t: AdjustTool) -> some View {
        let open = layout.isOpen(t), lifted = dragging == t
        return VStack(spacing: 0) {
            Rectangle().fill(Theme.rule).frame(height: 0.5)
            AdjustSectionHeader(session: session, tool: t, open: open, state: $state,
                                toggle: { withAnimation(.easeOut(duration: 0.18)) { layout.toggle(t) } })
                .gesture(reorder(t))
            if open {
                AdjustControl(session: session, tool: t, height: AdjustControl.columnHeight, state: $state)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
        .background(lifted ? Theme.card : Color.clear)
        .shadow(color: .black.opacity(lifted ? 0.25 : 0), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("adjust.section.\(t.rawValue)")
    }

    /// A header dragged up or down: the section follows the pointer, and the one it passes half of steps round it.
    private func reorder(_ t: AdjustTool) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { v in
                if dragging != t { dragging = t; passed = 0 }
                travel = v.translation.height
                while true {
                    guard let i = layout.order.firstIndex(of: t) else { break }
                    let y = travel - passed
                    if y > 0, i + 1 < layout.order.count, let h = heights[layout.order[i + 1]], y > h / 2 {
                        withAnimation(.easeOut(duration: 0.15)) { layout.shift(t, by: 1) }
                        passed += h
                    } else if y < 0, i > 0, let h = heights[layout.order[i - 1]], -y > h / 2 {
                        withAnimation(.easeOut(duration: 0.15)) { layout.shift(t, by: -1) }
                        passed -= h
                    } else { break }
                }
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.15)) { dragging = nil; travel = 0; passed = 0 }
            }
    }

    private func scroll(to t: AdjustTool, _ reader: ScrollViewProxy) {
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(t, anchor: .top) } }
    }
}

/// Move Up / Move Down: the drag's way for a pointer that does not drag.
struct AdjustMoveMenu: View {
    let tool: AdjustTool
    private var layout: AdjustLayout { .shared }
    var body: some View {
        Button(L("Move Up")) { withAnimation(.easeOut(duration: 0.18)) { layout.shift(tool, by: -1) } }
            .disabled(layout.order.first == tool)
        Button(L("Move Down")) { withAnimation(.easeOut(duration: 0.18)) { layout.shift(tool, by: 1) } }
            .disabled(layout.order.last == tool)
    }
}

/// A section's header: the disclosure chevron, the tool's symbol and name (with its views' menu while open: Tone,
/// Curve), the accent dot while it holds something, Temperature's eyedropper while open, ↺ while edited, and the
/// grip. A click anywhere else on it folds or unfolds the tool; a drag moves it.
struct AdjustSectionHeader: View {
    let session: OpenFrameSession
    let tool: AdjustTool
    let open: Bool
    @Binding var state: AdjustState
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        let atRest = session.adjustIsAtRest(tool)
        // The chrome is the column's one folding header (`FoldHeader`), which Develop's sections share.
        FoldHeader(open: open, symbol: tool.symbol, toggle: toggle) {
            centre
            if !atRest { Circle().fill(Theme.accent).frame(width: 5, height: 5).accessibilityHidden(true) }
        } accessory: {
            if open, tool == .temperature { NeutralPickButton(session: session, target: .print, diameter: 22) }
            if !atRest {
                small("arrow.counterclockwise", label: L("Reset") + " " + tool.title) {
                    session.resetAdjust(tool)
                }
                .accessibilityIdentifier("adjust.section.reset.\(tool.rawValue)")
            }
            Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.dim)
                .opacity(hovering ? 1 : 0.45)
                .frame(width: 16)
                .help(L("Drag to move"))
                .accessibilityHidden(true)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(open ? L("Put \(tool.title) away") : L("Open \(tool.title)"), action: toggle)
            Divider()
            AdjustMoveMenu(tool: tool)
        }
        .help(open ? L("Put \(tool.title) away") : L("Open \(tool.title)"))
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: open ? L("Put \(tool.title) away") : L("Open \(tool.title)"), toggle)
        .accessibilityIdentifier("adjust.header.\(tool.rawValue)")
    }

    @ViewBuilder private var centre: some View {
        let title = FoldTitle(tool.title, open: open)
        switch tool {
        case .tone where open:
            menu(state.tone.title) {
                Picker(L("Tone"), selection: $state.tone) { ForEach(TonePage.allCases) { Text($0.title).tag($0) } }
            }
        case .curve where open:
            menu(state.curveMode.title) {
                Picker(L("Curve"), selection: $state.curveMode) { ForEach(CurveMode.allCases) { Text($0.title).tag($0) } }
            }
        default:
            title
        }
    }

    private func menu<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) {
            HStack(spacing: 4) {
                Text(tool.title + " · " + title).font(Theme.Font.ui(12.5, .semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Theme.text)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(tool.title)
        .accessibilityValue(title)
    }

    private func small(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 22, height: 22)
                .background(Theme.card, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A tool's controls, wherever it is open: the host's one-at-a-time inspector and the column's sections.
struct AdjustControl: View {
    let session: OpenFrameSession
    let tool: AdjustTool
    let height: CGFloat
    @Binding var state: AdjustState

    /// The room a tool that draws its own (the curve, the wheels) is given in the column: Capture One's square plot.
    static var columnHeight: CGFloat { CurveTool.wideHeight }

    var body: some View {
        switch tool {
        case .hsl: HSLTool(session: session, hue: $state.hue)
        case .channel: ChannelMixerTool(session: session, output: $state.output)
        case .wheels: ColourWheelsTool(session: session, height: height, zone: $state.zone)
        case .curve: CurveTool(session: session, height: height - 10, channel: $state.curveChannel, mode: state.curveMode)
        case .lens: LensControls(session: session)
        default: AdjustSliders(session: session, tool: tool, tone: state.tone)
        }
    }
}
