//  TickRuler.swift — the host's slider: a scale that slides under a fixed mark.
//
//  Indigo's ruler, as `ruler()` draws it in gen.py: ticks every `spacing`
//  points, a taller one every `majorEvery`, the ends fading into the ground,
//  and a mark that never moves — the scale moves under it. Two faces:
//
//  - `.thumb`: a white capsule over the scale. Every control on the develop
//    page and in the Pro panels.
//  - `.dial`: an accent mark with numbers under the tall ticks. Film Exposure,
//    the one control whose position is itself a reading (stops).
//
//  **A control develops when it is released** (design/flow, the rules). The
//  binding follows the finger so the number beside the ruler is live, and
//  `onEditingChanged(false)` is the release: that is the moment a caller
//  commits, and the only moment. Nothing renders while a finger is moving
//  (RFC-036 §4: there is no live render).
//
//  A value past either end of `range` has no ticks: at ISO 64 the scale simply
//  stops at the mark, which is how the drawing shows a value at its limit.

import SwiftUI
import UIKit

struct TickRuler: View {
    enum Face { case thumb, dial }

    @Binding var value: Double
    let range: ClosedRange<Double>
    /// The value of one tick.
    var step: Double
    var majorEvery: Int = 3
    var spacing: CGFloat = 10.5
    var face: Face = .thumb
    /// Where the finger may leave the value; nil is one tick.
    var snap: Double? = nil
    /// A colour per position across the ruler (0 at its leading end): the
    /// temperature and tint scales, the filtration scales.
    var tint: ((Double) -> Color)? = nil
    /// The colour the ends fade into: the page, or a panel.
    var ground: Color = Theme.background
    /// `.dial` only: the number under a tall tick.
    var label: ((Double) -> String)? = nil
    /// `.thumb` only: the scale's own value, marked on it — a white tick with
    /// a dot over it (`gen_edit_v2.rrow`'s `home`): the film's own strength on
    /// an effect's scale, zero on Brightness. Not drawn while the thumb is on it.
    var home: Double? = nil
    /// True when a finger lands, false when it lifts.
    var onEditingChanged: (Bool) -> Void = { _ in }

    /// The unsnapped value while a finger is down, so the scale follows it
    /// exactly and only the published value lands on a stop.
    @State private var live: Double?
    @State private var anchor: Double?
    @State private var ownership = DragOwnership()
    @Environment(\.accessibilityReduceMotion) private var calm

    private var height: CGFloat { face == .dial ? 40 : 32 }
    private var fade: CGFloat { face == .dial ? 48 : 26 }

    var body: some View {
        GeometryReader { geo in
            let markX = geo.size.width / 2
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(&ctx, size: size, markX: markX) }
                HStack(spacing: 0) {
                    LinearGradient(colors: [ground, ground.opacity(0)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: fade)
                    Spacer(minLength: 0)
                    LinearGradient(colors: [ground.opacity(0), ground], startPoint: .leading, endPoint: .trailing)
                        .frame(width: fade)
                }
                .allowsHitTesting(false)
                mark.scaleEffect(anchor != nil && !calm ? 1.15 : 1).position(x: markX, y: face == .dial ? 9.5 : height / 2)
            }
            .contentShape(Rectangle())
            // Mac: a click on the scale brings the clicked tick under the mark — the value the
            // pointer was on — as one edit, committed as a release is.
            .onTapGesture(coordinateSpace: .local) { at in
                let raw = (value + Double((at.x - markX) / spacing) * step).clamped(to: range)
                onEditingChanged(true)
                value = snapped(raw)
                onEditingChanged(false)
            }
            .dragBesideScroll(onChanged: { g in
                guard ownership.update(x: g.translation.width, y: g.translation.height) else { return }
                let began = anchor == nil
                if began {
                    anchor = value
                    onEditingChanged(true)
                }
                let raw = ((anchor ?? value) - Double(g.translation.width / spacing) * step).clamped(to: range)
                live = raw
                let landed = snapped(raw)
                if landed != value { value = landed }
            }, onEnded: {
                if anchor != nil {
                    withAnimation(calm ? nil : .easeOut(duration: 0.12)) { live = nil }
                    onEditingChanged(false)
                }
                anchor = nil; ownership = DragOwnership()
            })
        }
        .frame(height: 44)
        .onDisappear {
            if anchor != nil { onEditingChanged(false) }
            live = nil; anchor = nil; ownership = DragOwnership()
        }
        .accessibilityElement()
        .accessibilityValue(String(format: "%.2f", value))
        .accessibilityAdjustableAction { direction in
            let s = snap ?? step
            value = (value + (direction == .increment ? s : -s)).clamped(to: range)
            onEditingChanged(false)
        }
    }

    @ViewBuilder private var mark: some View {
        switch face {
        case .thumb:
            RoundedRectangle(cornerRadius: 4).fill(Theme.selection).frame(width: 8, height: 26)
        case .dial:
            // An accent line with a small pointer over it: the dial's mark.
            ZStack(alignment: .top) {
                Capsule().fill(Theme.accent).frame(width: 2, height: 25).padding(.top, 4)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 10, y: 0))
                    p.addLine(to: CGPoint(x: 5, y: 5)); p.closeSubpath()
                }
                .fill(Theme.accent).frame(width: 10, height: 5)
            }
            .frame(width: 10, height: 29)
        }
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, markX: CGFloat) {
        let shown = live ?? value
        let first = Int((range.lowerBound / step).rounded(.up))
        let last = Int((range.upperBound / step).rounded(.down))
        guard last >= first, step > 0 else { return }
        let m = max(majorEvery, 1)
        for i in first...last {
            let x = markX + CGFloat((Double(i) * step - shown) / step) * spacing
            if x < -2 || x > size.width + 2 { continue }
            let major = ((i % m) + m) % m == 0
            switch face {
            case .thumb:
                // The tick under the thumb is the thumb.
                if abs(x - markX) < 3.5 { continue }
                // The scale's own value is drawn as its mark, below.
                if let home, abs(Double(i) * step - home) < step / 2 { continue }
                let half: CGFloat = major ? 9 : 5
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height / 2 - half))
                p.addLine(to: CGPoint(x: x, y: size.height / 2 + half))
                let colour = tint?(Double(x / max(size.width, 1)))
                    ?? (major ? Theme.secondaryText : Theme.dim.opacity(0.85))
                ctx.stroke(p, with: .color(colour), lineWidth: major ? 1.3 : 1)
            case .dial:
                var p = Path()
                p.move(to: CGPoint(x: x, y: major ? 4 : 9))
                p.addLine(to: CGPoint(x: x, y: 20))
                ctx.stroke(p, with: .color(major ? Theme.secondaryText : Theme.dim), lineWidth: major ? 1.2 : 0.8)
                if major, let label {
                    let text = Text(label(Double(i) * step)).font(Theme.Font.ui(9.5)).foregroundColor(Theme.dim)
                    ctx.draw(text, at: CGPoint(x: x, y: 31), anchor: .center)
                }
            }
        }
        if face == .thumb, let home, range.contains(home) {
            let x = markX + CGFloat((home - shown) / step) * spacing
            if abs(x - markX) >= 4, x > -2, x < size.width + 2 {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height / 2 - 9))
                p.addLine(to: CGPoint(x: x, y: size.height / 2 + 9))
                ctx.stroke(p, with: .color(Theme.text), lineWidth: 1.5)
                ctx.fill(Path(ellipseIn: CGRect(x: x - 1.9, y: size.height / 2 - 14 - 1.9, width: 3.8, height: 3.8)),
                         with: .color(Theme.text))
            }
        }
    }

    private func snapped(_ v: Double) -> Double {
        // The drawn home holds the finger within three quarters of a tick of it
        // (the owner, 2026-10-19: every slider snaps to its default).
        if face == .thumb, let home, range.contains(home), abs(v - home) <= step * 0.75 { return home }
        let s = snap ?? step
        guard s > 0 else { return v }
        return ((v / s).rounded() * s).clamped(to: range)
    }
}

/// `ruler_row`: a labelled value on the page's fixed track. It used to be a
/// scale that slid under a fixed mark; the owner asked for Capture One's row
/// on 2026-10-26 (see `ValueSlider`), so the label, the track and a number
/// that takes typing are the shared slider's. The call sites keep the
/// signature the drawings were measured against (`step`, `snap`, `home`).
struct RulerRow: View {
    let label: String
    /// The value as the page says it: "+0.10", "1.50", "1.00×".
    let valueText: String
    /// A quiet word after the label ("stops", "As Shot").
    var sub: String? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double
    var majorEvery: Int = 3
    var spacing: CGFloat = 10.5
    var snap: Double? = nil
    var tint: ((Double) -> Color)? = nil
    /// What the row sits on. Kept for the callers the drawings measured.
    var ground: Color = Theme.background
    var rulerDrop: CGFloat = 27
    var labelSize: CGFloat = 14
    /// The scale's own value, which the knob is held at nearby (one stop,
    /// 1.00×). nil is a scale with no home.
    var home: Double? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        ValueSlider(title: label, value: $value, range: range,
                    rest: home ?? range.lowerBound, step: snap ?? step,
                    text: { _ in valueText }, sub: sub, tint: tint,
                    detentAtRest: home != nil, showsRest: home != nil,
                    onEditingChanged: onEditingChanged)
            .accessibilityValue(valueText)
    }
}
