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

// MARK: - a strip that scrolls up and down inside the column

//  Develop's Film and Paper strips are grids since 2026-11-16 (`StockGridPanel.swift`): each scrolls its own cards up
//  and down, inside the column, which scrolls the whole panel up and down too.
//
//  **Round 4 (the owner's third hand test, 2026-11-16: "sometimes they fail")**: round 3 left a strip's scroll to UIKit
//  and took only what the strip could not follow, by the gesture's first movement and by `hitTest` from the hover's
//  pointer. Seen with a mouse's and a trackpad's events posted into the app (`MacStockGridHandCheck`): a plain wheel's
//  clicks over a strip that could follow them moved nothing at all; a wheel at the strip's foot, or up at its top, moved
//  the strip and never the column; and a scroll never left a strip at a row's rest, so the held maker's name cut the
//  row under it. So now **every gesture that begins over a strip is decided here and moved by hand**, start to end:
//
//  - **Where it begins**: the strip whose window the pointer is in, by its place on the window — its cards, the gaps
//    between them, its margins and the maker's name held at its top alike (no dead zones) — with nothing presented
//    over it. The pointer is the event's own place in the window, not the last hover.
//  - **What it moves**: its first up-or-down movement decides, and keeps, the gesture's: the strip where it can still
//    go that way, else the column. A gesture never changes hands: a strip that reaches its foot inside one stops there
//    (a scroll view in a scroll view on the Mac), and the next gesture goes on to the column.
//  - **A gesture** is a trackpad's from its begun phase to the end of its momentum; momentum with no phase before it
//    (a smooth-scrolling mouse utility) is one too; a plain wheel's clicks are one while they come less than 0.3 s apart.
//  - **Its end leaves the strip at a row's rest** (`StockGridLayout.rest`): straight under its maker's name, or the
//    strip's foot — the nearest, eased there.
//  - A gesture that begins over anything else is UIKit's, as before: the column's own, even as a strip comes under the
//    pointer while it scrolls (seen: the column keeps it).
//
//  The strip's own scroll indicator is drawn here too, at the panel's **left** edge (the owner: "both film and paper
//  will have their bar moved to the left side of the panel"), so it is not taken for the column's on the right; the
//  Mac's own scroller in the strip is hidden by `StripIndicator` (`.scrollIndicators(.hidden)` does not reach it).

extension View {
    /// Mac only: put on the content of a scroll view that scrolls up and down inside another that does (`StockGrid`).
    /// `rests`: where the strip may come to rest, for a window that tall (its rows' rests and its foot).
    func macScrollPassesToColumn(rests: @escaping (Double) -> [Double] = { _ in [] }) -> some View {
        background(MacNestedScroll(rests: rests))
    }
}

private struct MacNestedScroll: UIViewRepresentable {
    var rests: (Double) -> [Double]
    func makeUIView(context: Context) -> MacNestedScrolls.Probe {
        let v = MacNestedScrolls.Probe()
        v.isUserInteractionEnabled = false
        v.rests = rests
        return v
    }
    func updateUIView(_ v: MacNestedScrolls.Probe, context: Context) { v.rests = rests }
    static func dismantleUIView(_ v: MacNestedScrolls.Probe, coordinator: ()) { MacNestedScrolls.shared.unregister(v) }
}

/// Every such strip on screen, and the gesture under way. Asked by `MacScrollMonitor` after the rows are.
@MainActor
final class MacNestedScrolls {
    static let shared = MacNestedScrolls()

    /// The strip's marker in its scroll view's content: it finds the strip's scroll view and the column's over it, and
    /// keeps the strip's indicator.
    final class Probe: UIView {
        var rests: (Double) -> [Double] = { _ in [] }
        private(set) var indicator: StripIndicator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { MacNestedScrolls.shared.unregister(self); indicator?.detach(); return }
            _ = MacScrollMonitor.shared.start(in: window)
            MacNestedScrolls.shared.register(self)
            if let scroll = scrollView {
                if indicator?.scroll !== scroll { indicator?.detach(); indicator = StripIndicator(scroll) }
                indicator?.flash()
            }
        }
        var scrollView: UIScrollView? {
            sequence(first: superview, next: { $0?.superview }).lazy.compactMap { $0 as? UIScrollView }.first
        }
        var column: UIScrollView? {
            sequence(first: scrollView?.superview, next: { $0?.superview }).lazy.compactMap { $0 as? UIScrollView }.first
        }
    }

    struct Weak { weak var probe: Probe? }
    private(set) var probes: [Weak] = []

    /// The gesture under way: begun over a strip and not yet moved up or down, the strip's, the column's; or begun
    /// elsewhere (UIKit's, to its end).
    private enum Owner { case pending, strip, column, elsewhere }
    private struct Gesture {
        var probe: Weak?
        var owner: Owner
        var wheel: Bool
        var last = Date()
    }
    private var gesture: Gesture?
    private var lastPhaseEnd = Date.distantPast
    private var ending: DispatchWorkItem?
    private var aim: (view: ObjectIdentifier, y: CGFloat, at: Date)?

    /// A line of a wheel with no precise deltas, in the window's points.
    static let pointsPerLine: CGFloat = 40
    /// A plain wheel's clicks less than this apart are one gesture.
    static let wheelGap: TimeInterval = 0.3

    func register(_ p: Probe) {
        probes.removeAll { $0.probe == nil || $0.probe === p }
        probes.append(Weak(probe: p))
    }
    func unregister(_ p: Probe) { probes.removeAll { $0.probe == nil || $0.probe === p } }

    // NSEventPhase
    private static let began: UInt = 1, ended: UInt = 8, cancelled: UInt = 16, mayBegin: UInt = 32

    /// Whether `scroll` can still follow a scroll of `dy` (AppKit's: positive shows what is above).
    static func follows(_ scroll: UIScrollView, dy: CGFloat) -> Bool {
        let inset = scroll.adjustedContentInset
        let top = -inset.top, foot = max(top, scroll.contentSize.height + inset.bottom - scroll.bounds.height)
        return dy > 0 ? scroll.contentOffset.y > top + 0.5 : scroll.contentOffset.y < foot - 0.5
    }

    /// Whether the event was taken (a strip's or the column's, moved here, and consumed). `at`: the pointer in
    /// `window`'s points.
    func take(_ event: AnyObject, window: UIWindow, at: CGPoint) -> Bool {
        guard !probes.isEmpty, let e = event as? NSObject else { return false }
        let phase = (e.value(forKey: "phase") as? NSNumber)?.uintValue ?? 0
        let momentum = (e.value(forKey: "momentumPhase") as? NSNumber)?.uintValue ?? 0
        if phase == Self.mayBegin { return false }
        let dy = CGFloat((e.value(forKey: "scrollingDeltaY") as? NSNumber)?.doubleValue ?? 0)
        let precise = (e.value(forKey: "hasPreciseScrollingDeltas") as? NSNumber)?.boolValue ?? false
        let plain = phase == 0 && momentum == 0
        let now = Date()

        // A gesture starts: a trackpad's begun phase; momentum with no phase before it; a wheel's click after a rest.
        let starts = phase == Self.began
            || (phase == 0 && momentum == Self.began && now.timeIntervalSince(lastPhaseEnd) >= 0.3)
            || (plain && (gesture.map { !$0.wheel || now.timeIntervalSince($0.last) >= Self.wheelGap } ?? true))
        if starts {
            if let g = gesture, g.owner == .strip { settle(g) }
            gesture = probe(in: window, at: at).map { Gesture(probe: Weak(probe: $0), owner: .pending, wheel: plain) }
                ?? Gesture(probe: nil, owner: .elsewhere, wheel: plain)
        }
        if phase == Self.ended || phase == Self.cancelled { lastPhaseEnd = now }
        gesture?.last = now
        guard var g = gesture, g.owner != .elsewhere, let p = g.probe?.probe, let strip = p.scrollView, let column = p.column else {
            if momentum == Self.ended || momentum == Self.cancelled { gesture = nil }
            return false
        }
        if g.owner == .pending, dy != 0 { g.owner = Self.follows(strip, dy: dy) ? .strip : .column }
        gesture = g

        if g.owner != .pending, dy != 0 {
            let target = g.owner == .strip ? strip : column
            // AppKit's points to the window's ("scaled Catalyst mode" draws the window at 0.77), and the window's to the
            // scroll view's own: the interface scale draws the page larger (`InterfaceScale`).
            var scale: CGFloat = 1 / 0.77
            if let frame = ((e.value(forKey: "window") as? NSObject)?.value(forKey: "frame") as? NSValue)?.cgRectValue, frame.width > 0 {
                scale = window.bounds.width / frame.width
            }
            let drawn = target.convert(target.bounds, to: window).height / max(target.bounds.height, 1)
            let travel = -dy * (precise ? scale : Self.pointsPerLine) / max(drawn, 0.01)
            move(target, by: travel, animated: !precise)
            if target === strip { p.indicator?.flash() }
        }
        // Its end: momentum's, a phase's with none after it, a wheel's rest.
        ending?.cancel()
        if momentum == Self.ended || momentum == Self.cancelled {
            end()
        } else if phase == Self.ended || phase == Self.cancelled {
            schedule(after: 0.12)
        } else if plain {
            schedule(after: Self.wheelGap)
        } else {
            schedule(after: 0.5)                                    // a stream whose end never comes
        }
        return true
    }

    private func schedule(after seconds: Double) {
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.end() } }
        ending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func end() {
        ending?.cancel(); ending = nil
        if let g = gesture, g.owner == .strip { settle(g) }
        gesture = nil
    }

    /// The strip at the end of its gesture: eased to the nearest place of rest.
    private func settle(_ g: Gesture) {
        guard let p = g.probe?.probe, let strip = p.scrollView else { return }
        let from = aim.flatMap { $0.view == ObjectIdentifier(strip) && Date().timeIntervalSince($0.at) < 0.3 ? $0.y : nil } ?? strip.contentOffset.y
        let rests = p.rests(Double(strip.bounds.height))
        guard let to = rests.min(by: { abs($0 - Double(from)) < abs($1 - Double(from)) }), abs(CGFloat(to) - strip.contentOffset.y) > 0.5 else { return }
        aim = nil
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            strip.contentOffset = CGPoint(x: strip.contentOffset.x, y: CGFloat(to))
        }
        p.indicator?.flash()
    }

    /// The strip under `at`: its window on the page holds the point, it is shown, and nothing is presented over it.
    private func probe(in window: UIWindow, at: CGPoint) -> Probe? {
        probes.removeAll { $0.probe == nil }
        for w in probes.reversed() {
            guard let p = w.probe, p.window === window, let scroll = p.scrollView, let column = p.column, !Self.hidden(scroll) else { continue }
            guard scroll.bounds.contains(window.convert(at, to: scroll)) else { continue }
            // A menu, a sheet or a cover over the strip takes the scroll; the strip's own name and cards do not.
            if let top = window.hitTest(at, with: nil), !top.isDescendant(of: column) { continue }
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
        let lo = -inset.top
        let hi = max(lo, scroll.contentSize.height + inset.bottom - scroll.bounds.height)
        let id = ObjectIdentifier(scroll)
        var from = scroll.contentOffset.y
        if animated, let aim, aim.view == id, Date().timeIntervalSince(aim.at) < 0.3 { from = aim.y }
        let y = min(max(from + travel, lo), hi)
        aim = animated ? (id, y, Date()) : nil
        guard y != scroll.contentOffset.y else { return }
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: animated)
    }
}

/// A strip's scroll indicator at its left edge, the panel's: a thin rounded bar as long as the window's share of the
/// strip's cards, where the window is among them. Shown while the strip moves and a second after, as the Mac's overlay
/// scroll bars are; not shown where every card is in the window. A subview of the strip's scroll view, kept in its
/// window as it scrolls.
///
/// **The Mac's own scroller on the right is hidden here, not by `showsVerticalScrollIndicator`** (2026-11-16, the
/// owner's capture of a track and thumb inside each strip's height): on Mac Catalyst a `UIScrollView` draws AppKit's
/// scroller (`NSScrollerImp`) in a subview of its own, a `_UIScrollerImpContainerView` 15 pt wide at its right edge,
/// and that flag (which SwiftUI's `.scrollIndicators(.hidden)` sets too) does not reach it. The view tree, at rest and
/// just after a strip scroll: each strip `HostingScrollView` had `showsV=false` and such a container, seen, its knob
/// layer shown as the strip moved and its track layer opaque under "Always show scroll bars". So the container is
/// hidden, again at each move and size change of the strip and when the system's scroller style changes (a style
/// change replaces it). Proven by `MacStockGridHandCheck.nativeIndicators`.
@MainActor
final class StripIndicator {
    weak var scroll: UIScrollView?
    private let bar = UIView()
    private var watches: [NSKeyValueObservation] = []
    private var styleWatch: NSObjectProtocol?
    private var fade: DispatchWorkItem?
    static let width: CGFloat = 5, inset: CGFloat = 2.5
    /// The class Catalyst draws AppKit's scroller in, inside a scroll view (not public; matched by name, only read).
    static let nativeScrollerClass = "_UIScrollerImpContainerView"

    /// The strip's own native scrollers (vertical: as tall as wide or taller), hidden.
    static func hideNative(in scroll: UIScrollView) {
        for v in scroll.subviews where !v.isHidden && v.bounds.height >= v.bounds.width
            && NSStringFromClass(type(of: v)).hasSuffix(nativeScrollerClass) {
            v.isHidden = true
        }
    }

    init(_ scroll: UIScrollView) {
        self.scroll = scroll
        bar.accessibilityIdentifier = "v5.develop.grid.indicator"
        bar.isUserInteractionEnabled = false
        bar.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.42) : UIColor(white: 0, alpha: 0.38) }
        bar.layer.cornerRadius = Self.width / 2
        bar.alpha = 0
        scroll.showsVerticalScrollIndicator = false
        scroll.addSubview(bar)
        watches = [
            scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.flash() } },
            scroll.observe(\.contentSize, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.lay() } },
            scroll.observe(\.bounds, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.lay() } },
        ]
        // A change of "Show scroll bars" (or a mouse plugged in under "Automatic") rebuilds the scroller.
        styleWatch = NotificationCenter.default.addObserver(forName: Notification.Name("NSPreferredScrollerStyleDidChangeNotification"),
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { DispatchQueue.main.async { self?.lay() } }
        }
        lay()
    }

    func detach() {
        watches = []
        if let styleWatch { NotificationCenter.default.removeObserver(styleWatch) }
        styleWatch = nil
        bar.removeFromSuperview()
    }

    /// Shown for a moment, as the strip moves or appears.
    func flash() {
        lay()
        guard let scroll, scroll.contentSize.height > scroll.bounds.height + 0.5 else { bar.alpha = 0; return }
        fade?.cancel()
        if bar.alpha < 1 { UIView.animate(withDuration: 0.12) { self.bar.alpha = 1 } }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { UIView.animate(withDuration: 0.35) { self?.bar.alpha = 0 } }
        }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func lay() {
        guard let scroll else { return }
        Self.hideNative(in: scroll)
        let window = scroll.bounds.height, content = max(scroll.contentSize.height, 1)
        guard content > window + 0.5, window > 0 else { bar.alpha = 0; return }
        let track = window - 2 * Self.inset
        let length = max(track * window / content, 24)
        let range = max(content - window, 1)
        let at = min(max(scroll.contentOffset.y / range, 0), 1)
        bar.frame = CGRect(x: scroll.contentOffset.x + Self.inset, y: scroll.contentOffset.y + Self.inset + (track - length) * at,
                           width: Self.width, height: length)
        if scroll.subviews.last !== bar { scroll.bringSubviewToFront(bar) }
    }
}
