//  MacWheelRow.swift — a sideways scroll along a row of cards that scrolls sideways.
//
//  Mac change . Develop's Film and Paper strips. Up and down are the column's,
//  always, from a mouse's wheel and from a trackpad alike; only a **sideways** scroll moves a row (a
//  trackpad's two fingers left or right, a mouse's tilt wheel or Shift-wheel), and with a mouse the row's
//  scroll bar is dragged (the owner, 2026-11-05, replacing 2026-10-24's "wheel down scrolls right": a
//  row that turned the wheel sideways took the column's scroll whenever the pointer crossed it, and with
//  a trackpad up and down were not up and down).
//
//  A trackpad's sideways glide reaches the row's `UIScrollView`, but without its momentum
//  (`MacScrollZoom.swift`: the scroll-type pan never sees a momentum event), so a sideways gesture is
//  moved by hand, from the same AppKit monitor of the app's scroll events (`MacScrollMonitor`): two
//  fingers pushed to the left (natural scrolling) reveal the cards to the right, momentum included,
//  held to the row's ends, and the event is **consumed**. A gesture's axis is its first movement's,
//  kept to its end, momentum and all: one that starts up or down is the column's even as the pointer
//  crosses a row. Mac only.

import SwiftUI
import UIKit

extension View {
    /// Mac only: the wheel and the trackpad move the horizontal scroll view this content is in.
    /// Put it on the scroll view's content (`StockPreviewRow`).
    func macWheelScrollsRow() -> some View { background(MacWheelRow()) }
}

private struct MacWheelRow: UIViewRepresentable {
    func makeUIView(context: Context) -> MacWheelRows.Probe {
        let v = MacWheelRows.Probe()
        v.isUserInteractionEnabled = false
        return v
    }
    func updateUIView(_ v: MacWheelRows.Probe, context: Context) {}
    static func dismantleUIView(_ v: MacWheelRows.Probe, coordinator: ()) { MacWheelRows.shared.unregister(v) }
}

/// Every row on screen, and the gesture under way: see the head of the file. Asked by `MacScrollMonitor`
/// for each scroll event before anything else is.
@MainActor
final class MacWheelRows {
    static let shared = MacWheelRows()

    /// The row's marker in its scroll view's content: it finds the scroll view it is in.
    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { MacWheelRows.shared.unregister(self); return }
            _ = MacScrollMonitor.shared.start(in: window)       // the monitor, and the pointer on this window
            MacWheelRows.shared.register(self)
        }
        var scrollView: UIScrollView? {
            sequence(first: superview, next: { $0?.superview }).lazy.compactMap { $0 as? UIScrollView }.first
        }
    }

    struct Weak { weak var probe: Probe? }
    private(set) var probes: [Weak] = []
    /// The gesture under way: begun over a row and not yet moved (its axis still unknown), the row's, or not a row's.
    private enum Latch { case none, pending(Weak), row(Weak), elsewhere }
    private var latch = Latch.none
    private var lastPhaseEnd = Date.distantPast
    /// Where an animated wheel step is going, so the next click adds to it rather than to a row in motion.
    private var aim: (view: ObjectIdentifier, x: CGFloat, at: Date)?

    /// A line of a wheel with no precise deltas, in points along the row: about a third of a card.
    static let pointsPerLine: CGFloat = 40

    func register(_ p: Probe) {
        probes.removeAll { $0.probe == nil || $0.probe === p }
        probes.append(Weak(probe: p))
    }
    func unregister(_ p: Probe) { probes.removeAll { $0.probe == nil || $0.probe === p } }

    // NSEventPhase
    private static let began: UInt = 1, ended: UInt = 8, cancelled: UInt = 16, mayBegin: UInt = 32

    /// Whether the event moved a row (and is the row's alone). `at`: the pointer in `window`'s points.
    func take(_ event: AnyObject, window: UIWindow, at: CGPoint) -> Bool {
        guard !probes.isEmpty, let e = event as? NSObject else { return false }
        let phase = (e.value(forKey: "phase") as? NSNumber)?.uintValue ?? 0
        let momentum = (e.value(forKey: "momentumPhase") as? NSNumber)?.uintValue ?? 0
        if phase == Self.mayBegin { return false }
        let dx = CGFloat((e.value(forKey: "scrollingDeltaX") as? NSNumber)?.doubleValue ?? 0)
        let dy = CGFloat((e.value(forKey: "scrollingDeltaY") as? NSNumber)?.doubleValue ?? 0)
        let precise = (e.value(forKey: "hasPreciseScrollingDeltas") as? NSNumber)?.boolValue ?? false
        let sideways = abs(dx) > abs(dy)
        if phase == Self.began || (momentum == Self.began && phase == 0 && Date().timeIntervalSince(lastPhaseEnd) >= 0.3) {
            // A gesture starts: over a row, its axis is decided by its first movement.
            latch = probe(in: window, at: at).map { .pending(Weak(probe: $0)) } ?? .elsewhere
        }
        if case .pending(let w) = latch, dx != 0 || dy != 0 {
            latch = sideways ? .row(w) : .elsewhere
        }
        let target: Probe?
        if phase == 0 && momentum == 0 {
            target = sideways ? probe(in: window, at: at) : nil     // a plain wheel: only a sideways click is a row's
        } else if case .row(let w) = latch {
            target = w.probe
        } else {
            target = nil
        }
        if phase == Self.ended || phase == Self.cancelled { lastPhaseEnd = Date() }
        if momentum == Self.ended || momentum == Self.cancelled { latch = .none }
        guard let target, let scroll = target.scrollView else { return false }
        // AppKit's points to the window's ("scaled Catalyst mode" draws the window at 0.77).
        var scale: CGFloat = 1 / 0.77
        if let frame = ((e.value(forKey: "window") as? NSObject)?.value(forKey: "frame") as? NSValue)?.cgRectValue, frame.width > 0 {
            scale = window.bounds.width / frame.width
        }
        let travel = -dx * (precise ? scale : Self.pointsPerLine)
        if travel != 0 { move(scroll, by: travel, animated: !precise) }
        return true
    }

    /// The row under `at`, shown and with nothing drawn over it.
    private func probe(in window: UIWindow, at: CGPoint) -> Probe? {
        probes.removeAll { $0.probe == nil }
        for w in probes.reversed() {
            guard let p = w.probe, p.window === window, let scroll = p.scrollView, !Self.hidden(scroll) else { continue }
            guard scroll.bounds.contains(window.convert(at, to: scroll)) else { continue }
            // A menu, a sheet or a cover over the row takes the scroll.
            if let top = window.hitTest(at, with: nil), !top.isDescendant(of: scroll) { continue }
            return p
        }
        return nil
    }

    private static func hidden(_ v: UIView) -> Bool {
        var u: UIView? = v
        while let x = u { if x.isHidden || x.alpha < 0.01 { return true }; u = x.superview }
        var r: UIResponder? = v
        while let n = r { if let vc = n as? UIViewController { return vc.presentedViewController != nil }; r = n.next }
        return false
    }

    private func move(_ scroll: UIScrollView, by travel: CGFloat, animated: Bool) {
        let inset = scroll.adjustedContentInset
        let lo = -inset.left
        let hi = max(lo, scroll.contentSize.width + inset.right - scroll.bounds.width)
        let id = ObjectIdentifier(scroll)
        var from = scroll.contentOffset.x
        if animated, let aim, aim.view == id, Date().timeIntervalSince(aim.at) < 0.3 { from = aim.x }
        let x = min(max(from + travel, lo), hi)
        aim = animated ? (id, x, Date()) : nil
        guard x != scroll.contentOffset.x else { return }
        scroll.setContentOffset(CGPoint(x: x, y: scroll.contentOffset.y), animated: animated)
    }
}
