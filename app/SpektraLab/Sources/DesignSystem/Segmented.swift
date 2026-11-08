//  Segmented.swift — one choice among a few, as one control.
//
//  The desktop's `SegmentedSwitch` (1.2.2), sized for a finger: one track, one
//  white thumb in the app's selection language, and the unselected sides in
//  readable secondary ink. `seg` in gen_flow.py and `seg_control` in gen.py are
//  this control on two grounds — the field colour inside a grouped row, the
//  card colour on the bare page.
//
//  A plain view with a tap gesture per segment, as on the desktop: the thumb
//  slides between segments, which a row of separate buttons cannot do.

import SwiftUI

struct SegmentedSwitch<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    /// Each segment's width; nil shares the width the control is given.
    var segmentWidth: CGFloat? = nil
    var height: CGFloat = 28
    var track: Color = Theme.field
    var size: CGFloat = 12.5
    /// Options that are shown and cannot be chosen (Export, with the original
    /// away: 12 MP and Full).
    var disabled: Set<Option> = []
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                let off = disabled.contains(option)
                Text(title(option))
                    .font(Theme.Font.ui(size, on ? .semibold : .medium))
                    .foregroundStyle(on ? Theme.onSelection : Theme.secondaryText)
                    .opacity(off ? Theme.disabledOpacity : 1)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(maxWidth: segmentWidth == nil ? .infinity : nil)
                    .frame(width: segmentWidth, height: height)
                    .background {
                        if on {
                            Capsule().fill(Theme.selection).padding(2)
                                .matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !on, !off else { return }
                        withAnimation(.easeOut(duration: 0.15)) { selection = option }
                    }
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .background(Capsule().fill(track))
    }
}
