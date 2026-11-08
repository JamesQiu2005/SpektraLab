//  MacFlowBar.swift — the top bar of the crop page and the film-edge flow, on the Mac.
//
//  The owner, 2026-10-23: in Crop and in the film-edge flow the confirming button (Done, Next,
//  Develop) goes to the top right, where "1/4" stood, with grey round Reset · Undo · Redo to its
//  left, and no row of buttons at the bottom; the step pills already say how far along the flow
//  is. So the bar is: Cancel · the page's name · ↺ ↶ ↷ · the accent action. The name is shown only
//  where it fits whole beside the rest (never cut, never squeezed: ui-text-fit-and-density); the
//  crop page keeps its name in the tool row instead, and the film-edge flow's steps say where it is.
//
//  Undo and Redo are the flow's own (`MacFlowHistory`): a crop page and a film-edge flow edit a copy
//  of the frame's record until Done (or write it as they go, the film edge after the guide), and
//  the develop page's history is not theirs to walk. ⌘Z and ⇧⌘Z reach them through the menu bar's
//  Edit menu while the flow is in front (`MacFlowUndo`, asked first by `DevelopMenuCommands`: the
//  develop page under the cover keeps its own focused value, so a scene value from the flow loses).
//
//  Mac only, `#if targetEnvironment(macCatalyst)`: PAGES.md.

import SwiftUI
import UIKit

struct MacFlowBar: View {
    /// The bar's width: the column's.
    let width: CGFloat
    /// The page's name, shown where it fits whole; nil for none.
    var title: String?
    let cancel: () -> Void
    let canReset: Bool
    let reset: () -> Void
    let canUndo: Bool
    let undo: () -> Void
    let canRedo: Bool
    let redo: () -> Void
    let action: String
    var actionID: String? = nil
    let act: () -> Void

    static let height: CGFloat = 56
    private static let margin: CGFloat = 16
    private static let round: CGFloat = Theme.Metric.roundButton
    private static let roundGap: CGFloat = 8

    var body: some View {
        let cancelWidth = Self.width(of: L("Cancel"), size: 15, weight: .regular)
        let actionWidth = max(84, Self.width(of: action, size: 16, weight: .semibold) + 36).rounded(.up)
        let rounds = 3 * Self.round + 2 * Self.roundGap
        let room = width - 2 * Self.margin - cancelWidth - rounds - actionWidth - 3 * 12
        let titleWidth = title.map { Self.width(of: $0, size: 16, weight: .semibold) } ?? .infinity
        HStack(spacing: 12) {
            TextButton(title: L("Cancel"), color: Theme.secondaryText, action: cancel)
                .fixedSize()
                .accessibilityIdentifier("flow.cancel")
            if let title, titleWidth <= room {
                Text(title).font(Theme.Font.ui(16, .semibold)).lineLimit(1).fixedSize()
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            HStack(spacing: Self.roundGap) {
                grey("arrow.counterclockwise", L("Reset"), enabled: canReset, id: "flow.reset", reset)
                grey("arrow.uturn.backward", L("Undo"), enabled: canUndo, id: "flow.undo", undo)
                grey("arrow.uturn.forward", L("Redo"), enabled: canRedo, id: "flow.redo", redo)
            }
            CapsuleButton(title: action, width: actionWidth, action: act)
                .accessibilityIdentifier(actionID ?? "flow.action")
        }
        .padding(.horizontal, Self.margin)
        .frame(width: width, height: Self.height)
        .macPageActions(confirmTitle: action, confirm: act, cancel: cancel)
    }

    /// The app's grey round button: a symbol on a `Theme.card` disc, 44 pt.
    private func grey(_ symbol: String, _ label: String, enabled: Bool, id: String, _ action: @escaping () -> Void) -> some View {
        RoundButton(label: label, action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.text)
        }
        .rowEnabled(enabled)
        .disabled(!enabled)
        .accessibilityIdentifier(id)
    }

    /// A line's width in the system font, as `Theme.Font.ui` draws it.
    static func width(of text: String, size: CGFloat, weight: UIFont.Weight) -> CGFloat {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// The flow in front, for the menu bar's Undo and Redo (`DevelopMenuCommands`).
@MainActor
enum MacFlowUndo {
    struct Actions { let id: UUID; let undo: () -> Void; let redo: () -> Void }
    static var front: Actions?
}

extension View {
    /// Mac: while this flow is shown, ⌘Z and ⇧⌘Z are its `undo` and `redo`.
    func macFlowUndo(undo: @escaping () -> Void, redo: @escaping () -> Void) -> some View {
        modifier(MacFlowUndoHolder(undo: undo, redo: redo))
    }
}

private struct MacFlowUndoHolder: ViewModifier {
    let undo: () -> Void
    let redo: () -> Void
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content
            .onAppear { MacFlowUndo.front = .init(id: id, undo: undo, redo: redo) }
            .onDisappear { if MacFlowUndo.front?.id == id { MacFlowUndo.front = nil } }
    }
}

/// A flow's own Undo and Redo: the states it settled in, one step per gesture.
///
/// The flow reports its value whenever it changes (`observe`), and whether a gesture, a drag or a
/// dial is still under way (`busy`). A value becomes a step once it has rested for 0.35 s with
/// nothing under way, so a drag, a pinch, a scroll with its momentum or a ruler's turn is one step,
/// and a tap is one. Undo and Redo hand back the state to put in place; what the flow writes for
/// itself (the film edge switched on when the guide is left) is kept out of the value it reports.
@MainActor @Observable
final class MacFlowHistory<Value: Equatable> {
    private var history = EditHistory<Value>(limit: 64)
    private var settled: Value
    private var latest: Value
    private var pending: Task<Void, Never>?
    @ObservationIgnored var busy = false {
        didSet { if !busy, busy != oldValue { schedule() } }
    }

    init(_ opened: Value) { settled = opened; latest = opened }

    var canUndo: Bool { history.canUndo || latest != settled }
    var canRedo: Bool { history.canRedo && latest == settled }

    func observe(_ value: Value) {
        latest = value
        if value == settled { pending?.cancel(); return }
        schedule()
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, !self.busy else { return }
            self.flush()
        }
    }

    private func flush() {
        pending?.cancel()
        guard latest != settled else { return }
        history.record(from: settled, to: latest)
        settled = latest
    }

    /// The state before the last step, or nil.
    func undo() -> Value? {
        flush()
        guard let v = history.undo() else { return nil }
        settled = v; latest = v
        return v
    }

    /// The state the last undo took back, or nil.
    func redo() -> Value? {
        flush()
        guard let v = history.redo() else { return nil }
        settled = v; latest = v
        return v
    }
}
