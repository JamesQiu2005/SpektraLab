//  Rows.swift — grouped lists: the box, the hairline, the labels around them.
//
//  `group_box`, `sep`, `section_label`, `note` and `chev` from gen_flow.py.
//  Settings, Info, Sources, Storage, the Import and Export sheets and Copy
//  Settings are all made of these.

import SwiftUI
import UIKit

/// `group_box`: a rounded card that rows sit in.
struct GroupBox<Content: View>: View {
    var radius: CGFloat = Theme.Metric.groupRadius
    var fill: Color = Theme.card
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
    }
}

/// `sep`: the hairline between two rows, inset on the leading side.
struct RowSeparator: View {
    var leading: CGFloat = 14
    var trailing: CGFloat = 0
    var body: some View {
        Rectangle().fill(Theme.rule).frame(height: Theme.Metric.rule)
            .padding(.leading, leading).padding(.trailing, trailing)
    }
}

/// `section_label`: small capitals over a group.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Theme.Font.sectionLabel)
            .tracking(0.6)
            .foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `note`: the quiet paragraph under a group. Lines wrap where they fit; the
/// drawing's own breaks are not kept, because a host is not always 393 wide.
/// Its lines are `lead` apart, baseline to baseline: 1.42 times the size, as
/// `note()` sets them, unless the drawing says otherwise.
struct Note: View {
    let text: String
    var size: CGFloat = 11.5
    var color: Color = Theme.dim
    var alignment: TextAlignment = .leading
    var lead: CGFloat? = nil
    init(_ text: String, size: CGFloat = 11.5, color: Color = Theme.dim, alignment: TextAlignment = .leading,
         lead: CGFloat? = nil) {
        self.text = text; self.size = size; self.color = color; self.alignment = alignment; self.lead = lead
    }
    var body: some View {
        Text(text)
            .font(Theme.Font.ui(size))
            .foregroundStyle(color)
            .lineSpacing(LinePitch.spacing(for: lead ?? size * 1.42, size: size))
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }
}

/// The space to add between lines so they sit a given distance apart.
///
/// SwiftUI sets a system font's lines at a height of its own, which is neither
/// the font's ascent plus descent nor the same at every size, and offers only
/// extra spacing on top of it. So the natural pitch is measured once per size —
/// the height eleven lines take, less the height one takes, over ten — and the
/// difference is what is added. A pitch tighter than the natural one cannot be
/// had this way and is left natural.
@MainActor
enum LinePitch {
    private static var natural: [String: CGFloat] = [:]

    static func natural(size: CGFloat, weight: SwiftUI.Font.Weight = .medium) -> CGFloat {
        let key = "\(size)|\(weight)"
        if let known = natural[key] { return known }
        func height(lines: Int) -> CGFloat {
            let text = Array(repeating: "Ag", count: lines).joined(separator: "\n")
            let host = UIHostingController(rootView: Text(text).font(Theme.Font.ui(size, weight)).fixedSize())
            return host.sizeThatFits(in: CGSize(width: 2000, height: 20000)).height
        }
        let pitch = (height(lines: 11) - height(lines: 1)) / 10
        natural[key] = pitch
        return pitch
    }

    static func spacing(for pitch: CGFloat, size: CGFloat, weight: SwiftUI.Font.Weight = .medium) -> CGFloat {
        max(0, pitch - natural(size: size, weight: weight))
    }
}

extension View {
    /// A page that scrolls shows its rows through the status bar unless
    /// something covers them: this lays the page's own ground over the top
    /// unsafe area, and `extra` points below it for a row that stays put there
    /// (Settings' Done). The drawings draw these pages at rest, where nothing
    /// is under the bar; a list that has been scrolled is not drawn.
    func groundOverStatusBar(extra: CGFloat = 0) -> some View {
        overlay(alignment: .top) {
            // A strip `extra` tall at the safe area's top, whose ground runs
            // on up to the screen's edge.
            Color.clear.frame(height: extra)
                .background(Theme.background.ignoresSafeArea(edges: .top))
                .allowsHitTesting(false)
        }
    }
}

/// `chev`: a row's disclosure mark, 5 pt wide and 10 tall.
struct Chevron: View {
    var color: Color = Theme.dim
    var body: some View {
        Icon(.chevron, color: color).frame(width: 5, height: 10)
    }
}

/// A list row: a label, a value at the trailing edge, and a chevron when the
/// row goes somewhere. Settings and Info are stacks of these.
struct ValueRow: View {
    let label: String
    var value: String? = nil
    var valueColor: Color = Theme.dim
    var discloses = false
    var height: CGFloat = 44
    var action: (() -> Void)? = nil

    var body: some View {
        let row = HStack(spacing: 6) {
            Text(label).font(Theme.Font.listLabel).foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            if let value {
                Text(value).font(Theme.Font.rowValue).foregroundStyle(valueColor)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            // The value ends 6 pt before the chevron, whose tip is 5 pt inside the row's edge.
            if discloses { Chevron().padding(.trailing, 5) }
        }
        .padding(.horizontal, 14)
        .frame(height: height)
        .contentShape(Rectangle())
        if let action {
            Button(action: action) { row }.buttonStyle(PressStyle(scale: 1))
        } else {
            row
        }
    }
}

/// A folding section's header in the Mac's column: Edit › Adjust's (2026-11-11), and since the same day Develop's
/// too (the owner: "match Edit's collapse style"). Slim, 32 pt: the disclosure chevron at the left, turned down
/// while the section is open, an optional symbol, the name and what goes beside it (`label`), and at the right what
/// the section carries (`accessory`: a switch, a shelf's pill, ↺). A click anywhere on it that no control inside
/// takes folds or unfolds the section; the pointer over it tints it. Edit's sections draw their hairline above it
/// themselves; Develop's `ColumnSectionHeader` draws its own.
struct FoldHeader<Label: View, Accessory: View>: View {
    let open: Bool
    /// An SF Symbol after the chevron (Edit's tools); nil for none.
    var symbol: String? = nil
    /// Points before the chevron: a section folding inside another (Decode's Enlarger, High Dynamic Range).
    var indent: CGFloat = 0
    let toggle: () -> Void
    @ViewBuilder var label: () -> Label
    @ViewBuilder var accessory: () -> Accessory
    @State private var hovering = false

    static var height: CGFloat { 32 }
    /// Where the name starts from the header's leading edge with no symbol: the chevron's 12 pt and the gap.
    static var titleInset: CGFloat { 16 + 12 + 6 }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.dim)
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 12)
                .accessibilityHidden(true)
            if let symbol {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(open ? Theme.text : Theme.secondaryText)
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            label()
            Spacer(minLength: 4)
            accessory()
        }
        .padding(.leading, 16 + indent).padding(.trailing, 16)
        .frame(height: Self.height)
        .background(hovering ? Theme.card.opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: toggle)
    }
}

extension FoldHeader where Accessory == EmptyView {
    init(open: Bool, symbol: String? = nil, indent: CGFloat = 0, toggle: @escaping () -> Void,
         @ViewBuilder label: @escaping () -> Label) {
        self.init(open: open, symbol: symbol, indent: indent, toggle: toggle, label: label) { EmptyView() }
    }
}

/// A folding header's name: 12.5 pt, semibold and in the text colour while its section is open, medium and quieter
/// while it is folded (Edit › Adjust's).
struct FoldTitle: View {
    let text: String
    let open: Bool
    init(_ text: String, open: Bool) { self.text = text; self.open = open }
    var body: some View {
        Text(text).font(Theme.Font.ui(12.5, open ? .semibold : .medium))
            .foregroundStyle(open ? Theme.text : Theme.secondaryText).lineLimit(1)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(open ? L("Open") : L("Closed"))
    }
}

/// The hairline between the column's folding sections: the column's full width, half a point (Edit › Adjust's).
struct FoldRule: View {
    static var height: CGFloat { 0.5 }
    var body: some View { Rectangle().fill(Theme.rule).frame(height: Self.height) }
}
