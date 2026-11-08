//  MacLightTablePanel.swift — the ground the Mac Light Table's floating controls stand on (2026-10-26).
//
//  The owner: "loupe is the only page that could have the appearance of all control assets floating over the
//  base canvas, with rounded rectangle style, and simple Gaussian blur with clear rounded rectangle boundaries."
//
//  **This blur is the Light Table's alone.** The owner's rule is no glass and no blur anywhere else in the app:
//  every other page stands its controls on opaque `Theme` grounds. Do not reuse `MacPanelGround` elsewhere,
//  and do not turn it into Liquid Glass (no `.glassEffect`, no refraction, no specular edge, no glass button
//  styles): it is a plain blur of the table behind it, a dark tint, a 1 px boundary and continuous corners.
//  With Reduce Transparency on it is an opaque `Theme.panel` with the same boundary and corners.

import SwiftUI
import UIKit

/// A floating panel's ground: the table behind it blurred and tinted, a clear boundary, rounded corners.
/// The panel swallows its own clicks (the blur is a view that takes them; the opaque fill is hit-tested).
struct MacPanelGround: View {
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if opaque {
                shape.fill(Theme.panel)
            } else {
                MacTableBlur(dark: scheme != .light).clipShape(shape)
                shape.fill(Theme.panel.opacity(0.38))
            }
        }
        // One device pixel: a scene point is 0.77 of a Mac point here (`MacMetric.scale`).
        .overlay(shape.strokeBorder(scheme == .light ? Color.black.opacity(0.12) : Color.white.opacity(0.14),
                                    lineWidth: 1 / max(1, displayScale * MacMetric.scale)))
        .contentShape(shape)
    }
}

/// UIKit's blur of what is behind it (`UIBlurEffect` in a `UIVisualEffectView`), no vibrancy. The classic
/// `.dark` / `.light` styles: a blur and a tint, none of the system materials' adaptive look.
private struct MacTableBlur: UIViewRepresentable {
    let dark: Bool
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: dark ? .dark : .light))
    }
    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        view.effect = UIBlurEffect(style: dark ? .dark : .light)
    }
}

/// The panels' contents drawn in the develop page's points (`InterfaceScale`, `.padPoints`), so the discs are
/// the develop bar's size at every interface scale while the Light Table page itself is not scaled: laid out
/// in `1/factor` of the room it is offered and drawn `factor` times larger, crisp. The ground goes outside it
/// (`floatingPanel`), so the blur itself is never under a transform.
struct MacDevelopPoints<Content: View>: View {
    let factor: CGFloat
    @ViewBuilder var content: Content
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        MacScaledLayout(factor: factor) {
            content
                .environment(\.interfaceFactor, factor)
                .environment(\.displayScale, displayScale * factor)
                .scaleEffect(factor, anchor: .topLeading)
        }
    }
}

/// Offers its one child `1/factor` of the room and reports `factor` times the child's size; the child is placed
/// at the top leading corner at its own size and scaled up from there (`MacDevelopPoints`).
private struct MacScaledLayout: Layout {
    let factor: CGFloat

    private func down(_ p: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: p.width.map { $0 / factor }, height: p.height.map { $0 / factor })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let s = child.sizeThatFits(down(proposal))
        return CGSize(width: s.width * factor, height: s.height * factor)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width / factor, height: bounds.height / factor))
    }
}

extension View {
    /// This view on a floating panel (`MacPanelGround`), in develop points: the Light Table's only.
    func floatingPanel(factor: CGFloat, radius: CGFloat = MacLightTableFloat.radius) -> some View {
        MacDevelopPoints(factor: factor) { self }
            .background(MacPanelGround(radius: radius * factor))
    }
}
