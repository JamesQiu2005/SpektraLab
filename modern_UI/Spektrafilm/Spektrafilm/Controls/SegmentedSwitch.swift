//  SegmentedSwitch.swift — one choice among a few, as one control (1.2.2).
//
//  The Parameters rail's Pre-Dev / Post-Dev used to be two outlined capsules:
//  they read as two buttons rather than one choice, the unselected one looked
//  disabled, and the selected one wore the accent outline the Process button
//  wears, so a tab and an action looked alike. This is the user's option A
//  (`design-proposals/predev-switch-2026-09-30.svg`): one track in the plot
//  colour, one thumb in the app's selection language — the stock lists' white
//  capsule with near-black ink — and the unselected side in readable
//  secondary ink. The accent is left to actions and state; here it is only the
//  dot that says a side holds edits the rail is not showing.
//
//  A plain view with a tap gesture per segment, not a `Button`: macOS draws a
//  plate of its own inside even a `.plain` button (the stock lists' trap).

import SwiftUI

struct SegmentedSwitch<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    /// A dot after the title: this side holds edits.
    var marked: (Option) -> Bool = { _ in false }
    var markHelp: String = ""
    /// Whether a side can be chosen. A side that cannot greys and stops taking
    /// the click, with `reason` as its tooltip — Date Back's *Between* without
    /// a film edge, a face the format has no back for.
    var enabled: (Option) -> Bool = { _ in true }
    var reason: (Option) -> String = { _ in "" }
    /// What VoiceOver calls the switch ("Parameters", "Surface").
    var accessibilityName: String = ""

    @Namespace private var thumb

    /// The thumb holds a line of the switch's type with room around it, so
    /// the text never touches the capsule at any interface scale.
    private var thumbHeight: CGFloat { max(18, Theme.lineHeight(size: 10.5) + 4) }
    static var inset: CGFloat { 2 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let on = option == selection
                HStack(spacing: 4) {
                    Text(title(option))
                        .font(Theme.Font.body)
                        .foregroundStyle(on ? Theme.onSelection : Theme.Ink.secondary)
                        .fixedSize()
                    if marked(option) {
                        Circle().fill(Theme.accent)
                            .frame(width: 5, height: 5)
                            .help(markHelp)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: thumbHeight)
                .background {
                    if on {
                        Capsule().fill(Theme.selection)
                            .matchedGeometryEffect(id: "thumb", in: thumb)
                    }
                }
                .contentShape(Capsule())
                .onTapGesture { choose(option) }
                .rowEnabled(enabled(option), because: reason(option))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { choose(option) }
            }
        }
        .padding(Self.inset)
        .background(Capsule().fill(Theme.plot))
        // The switch as a whole is one adjustable control too: its name, the
        // side it is on, and a swipe to the next or previous side.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(title(selection))
        .accessibilityAdjustableAction { direction in
            guard let i = options.firstIndex(of: selection) else { return }
            let j = direction == .increment ? i + 1 : i - 1
            guard options.indices.contains(j) else { return }
            choose(options[j])
        }
    }

    /// V5's motion: the thumb slides in 150 ms, and under Reduce Motion it
    /// fades where it lands instead of travelling (`Theme.Motion`).
    private func choose(_ option: Option) {
        guard option != selection, enabled(option) else { return }
        withAnimation(Theme.Motion.quick) { selection = option }
    }
}
