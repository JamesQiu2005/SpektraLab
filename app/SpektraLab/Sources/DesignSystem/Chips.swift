//  Chips.swift — selection as a white capsule.
//
//  The desktop's selection language, carried to the host: one white capsule
//  with near-black ink marks the chosen one, and everything else is quiet
//  secondary ink. The accent is never a selection. Three shapes of the same
//  idea:
//
//  - `Chip`: one option among a few that sit side by side (the library's
//    filters, a tab's tools, the export recipes);
//  - `TabStrip`: the develop page's six stages, where only the chosen one has
//    a capsule at all;
//  - `SegmentedSwitch`: one choice inside a track (`Segmented.swift`).

import SwiftUI

/// `chip`: a capsule that is white when on and card-coloured when off.
struct Chip: View {
    let title: String
    var on = false
    var height: CGFloat = 30
    var size: CGFloat = 13
    var padding: CGFloat = 14
    var fill: Color = Theme.card
    /// A chip that is there but cannot be chosen now.
    var dim = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.ui(size, on ? .semibold : .medium))
                .foregroundStyle(on ? Theme.onSelection : (dim ? Theme.dim : Theme.secondaryText))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, padding)
                .frame(height: height)
                .background(Capsule().fill(on ? Theme.selection : fill))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A row of chips where exactly one is on: a tab's tools (Brightness ·
/// Filtration · Pre-flash), the crop's aspects.
struct ChipRow<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    var spacing: CGFloat = 8
    var height: CGFloat = 30
    var size: CGFloat = 13
    var padding: CGFloat = 14

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(options, id: \.self) { option in
                Chip(title: title(option), on: option == selection, height: height, size: size, padding: padding) {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option }
                }
            }
        }
    }
}

/// `tabs_row`: the six physical stages, spread across the page. The chosen
/// tab wears the white capsule; the rest are words.
struct TabStrip<Tab: Hashable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    /// A tap on the tab already chosen (the develop page folds its panel away).
    var onReselect: (() -> Void)? = nil
    @Namespace private var capsule

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                let on = tab == selection
                if index > 0 { Spacer(minLength: 0) }
                Text(title(tab))
                    .font(on ? Theme.Font.tabOn : Theme.Font.tab)
                    .foregroundStyle(on ? Theme.onSelection : Theme.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                    .padding(.horizontal, 5)
                    .background {
                        if on {
                            Capsule().fill(Theme.selection)
                                .matchedGeometryEffect(id: "tab", in: capsule)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !on else { onReselect?(); return }
                        withAnimation(.easeOut(duration: 0.18)) { selection = tab }
                    }
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, 12)
    }
}
