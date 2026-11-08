//  Buttons.swift — the three buttons the drawings use, and how they press.
//
//  `round_button` (a glyph on a card-coloured disc), `capsule_button` (the
//  accent action: Export, Next, Done, Continue) and `close_x` (a sheet's
//  close). Everything tappable in the interface is one of these, a chip
//  (`Chips.swift`) or a row.

import SwiftUI

/// The press: a control dims and settles a little, and comes back. One style
/// for every custom button, so a tap feels the same on every page.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    @Environment(\.accessibilityReduceMotion) private var calm
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !calm ? scale : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// `round_button`: a glyph on a disc. The drawings use 40 (the library's top
/// bar), 44 (the develop page's actions) and 46 (the library's action row).
struct RoundButton<Glyph: View>: View {
    var diameter: CGFloat = Theme.Metric.roundButton
    var fill: Color = Theme.card
    var label: String
    let action: () -> Void
    @ViewBuilder var glyph: () -> Glyph

    var body: some View {
        Button(action: action) {
            glyph()
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }
}

extension RoundButton where Glyph == Icon {
    /// The common case: one of the interface's glyphs.
    init(_ icon: SpkIcon, diameter: CGFloat = Theme.Metric.roundButton, fill: Color = Theme.card,
         tint: Color = Theme.text, label: String, action: @escaping () -> Void) {
        self.init(diameter: diameter, fill: fill, label: label, action: action) {
            Icon(icon, size: 22, color: tint)
        }
    }
}

/// A glyph on a disc, unlit on the card colour or lit (`lit`, the glyph then `onSelection`): the
/// develop bar's circles (`roundSymbol`, Undo · Redo · ··· · Paste · Compare) and, on the Mac, the
/// Light Table's floating tools, one drawing for both (2026-10-26). No button of its own: the bar
/// it stands in wraps it in one.
struct Disc<Glyph: View>: View {
    var diameter: CGFloat = Theme.Metric.roundButton
    var lit: Color? = nil
    @ViewBuilder var glyph: () -> Glyph

    /// An SF Symbol's point size on a disc: 18 on the 44 pt disc, scaled with it.
    static func symbolSize(_ diameter: CGFloat) -> CGFloat { diameter * 18 / Theme.Metric.roundButton }

    var body: some View {
        glyph()
            .foregroundStyle(lit == nil ? Theme.text : Theme.onSelection)
            .frame(width: diameter, height: diameter)
            .background(lit ?? Theme.card, in: Circle())
    }
}

/// `capsule_button`: the page's one action in accent, or a quiet second one on
/// the card colour (Stop, Find Its Folder).
struct CapsuleButton: View {
    let title: String
    var primary = true
    var height: CGFloat = Theme.Metric.capsuleHeight
    /// Nil fills the width it is given; a number fixes it (Export on the
    /// develop page is 112).
    var width: CGFloat? = nil
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.button)
                .foregroundStyle(primary ? Theme.onSelection : Theme.text)
                .lineLimit(1)
                .frame(maxWidth: width == nil ? .infinity : nil)
                .frame(width: width, height: height)
                .background(Capsule().fill(primary ? Theme.accent : Theme.card))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .rowEnabled(enabled)
    }
}

/// `close_x`: a sheet's close button.
struct CloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Icon(.close, color: Theme.secondaryText)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.card))
                // The disc is 30; a finger needs 44.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(L("Close"))
    }
}

/// A word that is a button: Select, Cancel, Reset, Done, Change.
struct TextButton: View {
    let title: String
    var color: Color = Theme.text
    var font: SwiftUI.Font = Theme.Font.ui(15)
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(font).foregroundStyle(color)
                .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}
