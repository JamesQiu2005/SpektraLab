//  MacSettingsParts.swift — the rows the Mac's Settings page is built of (2026-10-24).
//
//  v2's language at macOS's sizes (design/MAC-LIBRARY-UI.md §4, the Mac points of `MacMetric`): black
//  ground, a group as a panel-coloured box under a small-capitals heading, rows of 13-pt words with the
//  control at the trailing edge, an 11-pt caption under a row when the row needs one (said where the
//  setting is, never as hover help: RFC-016 §5.2, the v1 Settings' rule). Two tiers of line: the box's
//  own edge between groups, a faint hairline between the rows of one box.
//
//  Words are never cut and never end in "…": a label wraps (`fixedSize(horizontal: false, …)`), and a
//  control's own words are short constants. Mac only.

import SwiftUI

enum MacSettingsMetric {
    /// The section list's width, Mac points.
    static let sidebar: CGFloat = 200
    /// A row's least height: a regular macOS control (22) and its gap.
    static let row: CGFloat = 30
    /// The content's widest: past it the rows would be read across a whole display.
    static let readable: CGFloat = 720
    static let inset: CGFloat = 12
}

/// A group: its heading in small capitals, its rows in one box, and a caption under the box.
struct MacSettingsGroup<Content: View, Accessory: View>: View {
    let title: String?
    var footer: String? = nil
    /// A heading of the page's own words is in small capitals; a name the user gave (a recipe's) is not.
    var capitals = true
    let accessory: () -> Accessory
    let content: () -> Content

    /// `accessory`: a control at the heading's trailing edge (*Open Catalog or Folder…*).
    init(title: String?, footer: String? = nil, capitals: Bool = true, @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.footer = footer
        self.capitals = capitals
        self.content = content
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MacMetric.pt(6)) {
            if let title {
                HStack(alignment: .lastTextBaseline, spacing: MacMetric.pt(8)) {
                    Text(capitals ? title.uppercased() : title).font(MacMetric.font(capitals ? 11 : 12, .semibold)).tracking(capitals ? 0.4 : 0).foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    accessory()
                }
                .padding(.horizontal, MacMetric.pt(4))
            }
            VStack(spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: MacMetric.pt(8), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: MacMetric.pt(8), style: .continuous).strokeBorder(Theme.wall, lineWidth: 1))
            if let footer {
                MacSettingsCaption(footer).padding(.horizontal, MacMetric.pt(4))
            }
        }
    }
}

extension MacSettingsGroup where Accessory == EmptyView {
    init(title: String?, footer: String? = nil, capitals: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, footer: footer, capitals: capitals, content: content, accessory: { EmptyView() })
    }
}

/// One row: its words at the leading edge, the control at the trailing edge, and what the setting does
/// under them, the row's whole width. `last` leaves off the hairline under it.
struct MacSettingsRow<Control: View>: View {
    let label: String
    var detail: String? = nil
    var caption: String? = nil
    var last = false
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: MacMetric.pt(3)) {
            HStack(alignment: .center, spacing: MacMetric.pt(12)) {
                VStack(alignment: .leading, spacing: MacMetric.pt(1)) {
                    Text(label).font(MacMetric.font(13)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail).font(MacMetric.font(11)).foregroundStyle(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                control()
            }
            if let caption { MacSettingsCaption(caption) }
        }
        .padding(.horizontal, MacMetric.pt(MacSettingsMetric.inset))
        .padding(.vertical, MacMetric.pt(5))
        .frame(minHeight: MacMetric.pt(MacSettingsMetric.row))
        .overlay(alignment: .bottom) {
            if !last { MacSettingsHairline().padding(.leading, MacMetric.pt(MacSettingsMetric.inset)) }
        }
    }
}

extension MacSettingsRow where Control == EmptyView {
    init(label: String, detail: String? = nil, caption: String? = nil, last: Bool = false) {
        self.init(label: label, detail: detail, caption: caption, last: last) { EmptyView() }
    }
}

/// A value read, not set: the words at the leading edge, the value at the trailing edge in the
/// secondary grey, wrapping when it is long (a path, an engine's stamp).
struct MacSettingsValueRow: View {
    let label: String
    let value: String
    var caption: String? = nil
    var last = false

    var body: some View {
        MacSettingsRow(label: label, caption: caption, last: last) {
            Text(value).font(MacMetric.font(12)).monospacedDigit().foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: MacMetric.pt(360), alignment: .trailing)
                .textSelection(.enabled)
        }
    }
}

/// The faint line between two rows of one box (the lower of the two tiers).
struct MacSettingsHairline: View {
    var body: some View { Rectangle().fill(Theme.wall).frame(height: 1) }
}

/// A caption: what a setting does, in the page's smallest type, wrapping.
struct MacSettingsCaption: View {
    let text: String
    var color: Color = Theme.dim
    init(_ text: String, color: Color = Theme.dim) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text).font(MacMetric.font(11)).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Mac's check box (the import page's): a square ticked in the accent, at the row's trailing edge.
struct MacSettingsCheckbox: View {
    let label: String
    @Binding var on: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button { on.toggle() } label: {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .font(MacMetric.font(15)).foregroundStyle(on ? Theme.accent : Theme.dim)
                .frame(width: MacMetric.pt(22), height: MacMetric.pt(22))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : Theme.disabledOpacity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(on ? L("On") : L("Off"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A pop-up button: the chosen value and the up-down chevron on the card colour, a menu of the
/// choices with the chosen one ticked. `allowed` false shows a choice greyed, and it takes nothing.
struct MacSettingsPopUp<Value: Hashable>: View {
    let label: String
    let options: [(Value, String)]
    @Binding var selection: Value
    var allowed: (Value) -> Bool = { _ in true }
    /// What the button says when the selection is none of the options (a kept value from elsewhere).
    var other: String? = nil
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                if allowed(option.0) {
                    Button { selection = option.0 } label: {
                        if option.0 == selection { Label(option.1, systemImage: "checkmark") } else { Text(option.1) }
                    }
                } else {
                    Button(option.1) {}.disabled(true)
                }
            }
        } label: {
            MacSettingsPopUpFace(text: options.first { $0.0 == selection }?.1 ?? other ?? "")
                .opacity(enabled ? 1 : Theme.disabledOpacity)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(label)
        .accessibilityValue(options.first { $0.0 == selection }?.1 ?? other ?? "")
    }
}

/// A pop-up button's face, for a menu built by hand.
struct MacSettingsPopUpFace: View {
    let text: String
    var body: some View {
        HStack(spacing: MacMetric.pt(6)) {
            Text(text).font(MacMetric.font(12, .medium)).foregroundStyle(Theme.text)
                .fixedSize()
            Image(systemName: "chevron.up.chevron.down").font(MacMetric.font(9, .semibold)).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, MacMetric.pt(8))
        .frame(minHeight: MacMetric.pt(22))
        .background(Theme.card, in: RoundedRectangle(cornerRadius: MacMetric.pt(5), style: .continuous))
        .contentShape(Rectangle())
    }
}

/// The page's buttons at macOS's sizes (the import page's): the primary one in the accent, the others on
/// `Theme.card`, a destructive one in the danger red.
struct MacSettingsButtonStyle: ButtonStyle {
    enum Kind { case primary, plain, destructive }
    var kind: Kind = .plain
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MacMetric.font(12, kind == .primary ? .semibold : .medium))
            .foregroundStyle(kind == .primary ? Theme.onSelection : kind == .destructive ? Theme.danger : Theme.text)
            .padding(.horizontal, MacMetric.pt(10))
            .frame(minHeight: MacMetric.pt(22))
            .background(kind == .primary ? Theme.accent : Theme.card,
                        in: RoundedRectangle(cornerRadius: MacMetric.pt(5), style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : Theme.disabledOpacity)
            .fixedSize()
            .contentShape(Rectangle())
    }
}

/// A text field on the card colour, at a small control's height.
struct MacSettingsField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil
    var onCommit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .font(MacMetric.font(12)).textFieldStyle(.plain)
            .focused($focused)
            .onSubmit { onCommit() }
            .onChange(of: focused) { _, now in if !now { onCommit() } }
            .padding(.horizontal, MacMetric.pt(6))
            .frame(width: width.map { MacMetric.pt($0) }, height: MacMetric.pt(22))
            .background(Theme.card, in: RoundedRectangle(cornerRadius: MacMetric.pt(5), style: .continuous))
    }
}
