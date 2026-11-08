//  MacScrollZoom.swift — a mouse's wheel and a trackpad's two-finger scroll, on a picture.
//
//  The owner, 2026-10-23: "the frame view is not made for a mouse/trackpad: scroll to zoom
//  in/out does not work." SwiftUI on the operating system has no scroll-wheel input, and UIKit under Mac
//  Catalyst gives a scroll to a `UIPanGestureRecognizer` that allows scroll types — but only
//  its scroll phase: **the momentum after it never reaches the recogniser** (measured
//  2026-10-23 with synthetic CGEvents: a phased scroll of 10 events and 12 momentum events gave
//  10 changes and an end; 15 momentum events alone gave nothing at all). A Logitech mouse under
//  Mac Mouse Fix scrolls as a trackpad does, phased and with momentum, so most of a wheel turn
//  was lost, and on the crop page and the film-edge flow there was no scroll zoom at all.
//
//  So the scroll is read where AppKit has it whole: one local monitor of the app's scroll
//  events (`NSEvent`, reached through the Objective-C runtime — Catalyst links AppKit but its
//  headers are not ours), each event with its scroll phase, its momentum phase and its
//  precise or line delta. A **scroll session** runs from the first event to the end of its
//  momentum (or to 0.1 s after its scroll phase ends with no momentum after it, or 0.2 s after
//  the last of a plain wheel's clicks, which have no phases; momentum with no scroll phase
//  before it starts a session of its own; 0.5 s after any other event whose end never comes, and at
//  a new gesture's start, 2026-11-05), and goes to the one registered
//  view under the pointer — the pointer as UIKit's own hover has it, in the window's points —
//  where nothing is presented over it and no other scroll view is on top (the side panel keeps
//  its own scrolling: the monitor consumes only what a row of cards takes, `MacWheelRow.swift`). If the monitor cannot be made, the
//  old scroll-type pan recogniser is used instead.
//
//  The view tells its owner the session's vertical travel since it began, in the window's
//  points (a line of a plain wheel is 24 of them), and where the pointer is in the view's own
//  space; the owner turns it into a zoom (`DevelopCanvas`, the crop page, the film-edge flow,
//  the Light Table). A trackpad's pinch is not a scroll: it stays the window's pinch.
//  Mac only, `#if targetEnvironment(macCatalyst)`: PAGES.md.

import ObjectiveC
import SwiftUI
import UIKit

struct MacScrollZoom: UIViewRepresentable {
    enum Phase { case began, changed, ended }
    /// (phase, vertical travel since it began in points — positive is a wheel rolled away
    /// from the user, or two fingers pushed up with "natural" scrolling off —, the pointer).
    var onScroll: (Phase, CGFloat, CGPoint) -> Void

    func makeUIView(context: Context) -> Probe {
        let v = Probe()
        v.isUserInteractionEnabled = false      // it is never hit: the monitor (or the window's recogniser) does the work
        v.onScroll = onScroll
        return v
    }

    func updateUIView(_ v: Probe, context: Context) { v.onScroll = onScroll }

    static func dismantleUIView(_ v: Probe, coordinator: ()) { v.detach() }

    final class Probe: UIView, UIGestureRecognizerDelegate {
        var onScroll: ((Phase, CGFloat, CGPoint) -> Void)?
        private var recognizer: UIPanGestureRecognizer?
        private weak var host: UIView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            if MacScrollMonitor.shared.start(in: window) {
                MacScrollMonitor.shared.register(self, accepts: { [weak self] p in self?.takes(p) ?? false }) { [weak self] phase, dy, p in
                    self?.onScroll?(phase, dy, p)
                }
                return
            }
            // No monitor: the scroll phase alone, through UIKit.
            let r = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
            r.allowedScrollTypesMask = .all          // the wheel's clicks and the trackpad's glide
            r.allowedTouchTypes = []                 // no finger and no click: those are the picture's
            r.cancelsTouchesInView = false
            r.delaysTouchesBegan = false
            r.delaysTouchesEnded = false
            r.delegate = self
            window.addGestureRecognizer(r)
            recognizer = r
            host = window
        }

        func detach() {
            MacScrollMonitor.shared.unregister(self)
            if let recognizer { host?.removeGestureRecognizer(recognizer) }
            recognizer = nil
        }

        /// Only over this view, only while it is shown, and only with nothing presented over it.
        func takes(_ p: CGPoint) -> Bool {
            guard let w = window, !isHiddenOrUnder, bounds.contains(p) else { return false }
            // Something drawn over this point in the same window (a menu, a cover) takes it.
            let top = w.hitTest(convert(p, to: w), with: nil)
            if let top, let scroll = sequence(first: top, next: { $0.superview }).first(where: { $0 is UIScrollView }),
               !scroll.isDescendant(of: self), !self.isDescendant(of: scroll) {
                return false
            }
            return true
        }

        override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {   // also the delegate's
            takes(g.location(in: self))
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        private var isHiddenOrUnder: Bool {
            var v: UIView? = self
            while let u = v { if u.isHidden || u.alpha < 0.01 { return true }; v = u.superview }
            var r: UIResponder? = self
            while let n = r { if let vc = n as? UIViewController { return vc.presentedViewController != nil }; r = n.next }
            return false
        }

        @objc private func scrolled(_ g: UIPanGestureRecognizer) {
            let p = g.location(in: self)
            let dy = g.translation(in: self).y
            #if DEBUG
            if MacScrollZoom.logs { NSLog("macscroll pan %@ dy %.1f at %.0f,%.0f", MacScrollZoom.name(g.state), dy, p.x, p.y) }
            #endif
            switch g.state {
            case .began: onScroll?(.began, dy, p)
            case .changed: onScroll?(.changed, dy, p)
            case .ended, .cancelled, .failed: onScroll?(.ended, dy, p)
            default: break
            }
        }
    }
}

/// The app's scroll events, whole: see the head of the file. One per app, on the main thread.
@MainActor
final class MacScrollMonitor {
    static let shared = MacScrollMonitor()

    typealias Handler = (MacScrollZoom.Phase, CGFloat, CGPoint) -> Void
    struct Entry {
        weak var view: UIView?
        let accepts: (CGPoint) -> Bool
        let handler: Handler
    }
    fileprivate(set) var entries: [Entry] = []
    private var monitor: AnyObject?
    private var failed = false
    /// The pointer, per window, in that window's points (UIKit's hover).
    fileprivate var pointer: [ObjectIdentifier: CGPoint] = [:]
    fileprivate weak var pointerWindow: UIWindow?
    private var hovered: Set<ObjectIdentifier> = []

    /// The session under way: its view, its travel, and whether it has begun for the view.
    private struct Session {
        let entry: Entry
        let window: UIWindow
        var travel: CGFloat = 0
        var momentum = false
    }
    private var session: Session?
    private var ending: DispatchWorkItem?
    private var lastPhaseEnd = Date.distantPast

    /// A line of a wheel with no precise deltas, in window points: one click is about ×1.15.
    static let pointsPerLine: CGFloat = 24

    /// Makes the monitor once (and the hover on `window`); false when AppKit's monitor cannot be had.
    func start(in window: UIWindow) -> Bool {
        watchPointer(in: window)
        return install()
    }

    /// UIKit's hover on `window`, once: where the pointer is, in its points.
    fileprivate func watchPointer(in window: UIWindow) {
        let id = ObjectIdentifier(window)
        guard !hovered.contains(id) else { return }
        hovered.insert(id)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovering(_:)))
        hover.cancelsTouchesInView = false
        window.addGestureRecognizer(hover)
    }

    /// The monitor, made once; false when AppKit's monitor cannot be had.
    func install() -> Bool {
        if monitor != nil { return true }
        if failed { return false }
        guard let cls: AnyClass = NSClassFromString("NSEvent"),
              let method = class_getClassMethod(cls, NSSelectorFromString("addLocalMonitorForEventsMatchingMask:handler:")) else {
            failed = true
            return false
        }
        typealias Add = @convention(c) (AnyClass, Selector, UInt64, @escaping @convention(block) (AnyObject) -> AnyObject?) -> AnyObject?
        let add = unsafeBitCast(method_getImplementation(method), to: Add.self)
        let block: @convention(block) (AnyObject) -> AnyObject? = { event in
            // Never consumed, so a scroll view under the pointer still scrolls — but for a row of cards
            // moved by it (`MacWheelRows`, 2026-10-24), whose column must not scroll with it.
            let taken = MainActor.assumeIsolated { MacScrollMonitor.shared.scrolled(event) }
            return taken ? nil : event
        }
        monitor = add(cls, NSSelectorFromString("addLocalMonitorForEventsMatchingMask:handler:"), 1 << 22, block)   // NSEventMaskScrollWheel
        if monitor == nil { failed = true }
        return monitor != nil
    }

    func register(_ view: UIView, accepts: @escaping (CGPoint) -> Bool, handler: @escaping Handler) {
        entries.removeAll { $0.view == nil || $0.view === view }
        entries.append(Entry(view: view, accepts: accepts, handler: handler))
    }

    func unregister(_ view: UIView) {
        entries.removeAll { $0.view == nil || $0.view === view }
        if let s = session, s.entry.view == nil || s.entry.view === view { session = nil; ending?.cancel() }
    }

    @objc private func hovering(_ g: UIHoverGestureRecognizer) {
        guard let w = g.view as? UIWindow else { return }
        pointer[ObjectIdentifier(w)] = g.location(in: w)
        pointerWindow = w
    }

    // NSEventPhase
    private static let began: UInt = 1, changed: UInt = 4, ended: UInt = 8, cancelled: UInt = 16, mayBegin: UInt = 32

    /// Whether a row of cards took the event (`MacWheelRows`), which is then the row's alone.
    private func scrolled(_ event: AnyObject) -> Bool {
        let e = event as? NSObject
        for entry in entries { if let w = entry.view?.window { watchPointer(in: w) } }
        // Where the event is, from AppKit, for a window whose hover has not yet seen the pointer:
        // the window's content fills its frame (the title bar is drawn over it), y runs upward.
        if let w = entries.lazy.compactMap({ $0.view?.window }).first(where: { self.pointer[ObjectIdentifier($0)] == nil }),
           let at = (e?.value(forKey: "locationInWindow") as? NSValue)?.cgPointValue,
           let frame = ((e?.value(forKey: "window") as? NSObject)?.value(forKey: "frame") as? NSValue)?.cgRectValue, frame.width > 0 {
            let k = w.bounds.width / frame.width
            pointer[ObjectIdentifier(w)] = CGPoint(x: at.x * k, y: (frame.height - at.y) * k)
            if pointerWindow == nil { pointerWindow = w }
        }
        if let w = pointerWindow, let at = pointer[ObjectIdentifier(w)], MacWheelRows.shared.take(event, window: w, at: at) {
            return true
        }
        let phase = (e?.value(forKey: "phase") as? NSNumber)?.uintValue ?? 0
        let momentum = (e?.value(forKey: "momentumPhase") as? NSNumber)?.uintValue ?? 0
        let delta = CGFloat((e?.value(forKey: "scrollingDeltaY") as? NSNumber)?.doubleValue ?? 0)
        let precise = (e?.value(forKey: "hasPreciseScrollingDeltas") as? NSNumber)?.boolValue ?? false
        // AppKit's points are larger than the window's: "scaled Catalyst mode" draws the window at 0.77.
        var scale: CGFloat = 1 / 0.77
        if let window = pointerWindow,
           let frame = ((e?.value(forKey: "window") as? NSObject)?.value(forKey: "frame") as? NSValue)?.cgRectValue, frame.width > 0 {
            scale = window.bounds.width / frame.width
        }
        let step = precise ? delta * scale : delta * Self.pointsPerLine
        #if DEBUG
        if MacScrollZoom.logs {
            NSLog("macscroll event phase %lu momentum %lu delta %.2f precise %d -> %.1f", phase, momentum, delta, precise ? 1 : 0, step)
        }
        #endif
        if phase == Self.mayBegin { return false }                  // fingers resting on a trackpad: nothing yet

        if phase == Self.ended || phase == Self.cancelled { lastPhaseEnd = Date() }
        // A new gesture while the last is still open (its end never came): the last is ended first.
        if session != nil, phase == Self.began { finish() }
        if session == nil {
            // A momentum tail of a scroll that began elsewhere (over the side panel, or given away)
            // starts nothing; momentum with no scroll before it (a mouse's smooth scrolling) does.
            let tail = momentum != 0 && (momentum != Self.began || Date().timeIntervalSince(lastPhaseEnd) < 0.3)
            guard !tail, step != 0 || phase == Self.began, let s = begin() else { return false }
            session = s
            session?.travel = step
            deliver(.began)
        } else {
            session?.travel += step
            if momentum != 0 { session?.momentum = true }
            if step != 0 { deliver(.changed) }
        }

        ending?.cancel()
        if momentum == Self.ended || momentum == Self.cancelled || phase == Self.cancelled {
            finish()
        } else if phase == Self.ended {
            schedule(after: 0.1)                                    // momentum may follow
        } else if phase == 0 && momentum == 0 {
            schedule(after: 0.2)                                    // a plain wheel: no phases, ends when it rests
        } else {
            // A stream whose end never comes (a smooth-scrolling mouse utility, an event lost): it ends when
            // it rests (2026-11-05: measured, the picture stayed unsettled below fit and would not pan).
            schedule(after: 0.5)
        }
        return false
    }

    private func begin() -> Session? {
        guard let window = pointerWindow, let at = pointer[ObjectIdentifier(window)] else { return nil }
        entries.removeAll { $0.view == nil }
        for entry in entries.reversed() {
            guard let view = entry.view, view.window === window else { continue }
            if entry.accepts(window.convert(at, to: view)) { return Session(entry: entry, window: window) }
        }
        return nil
    }

    private func deliver(_ phase: MacScrollZoom.Phase) {
        guard let s = session, let view = s.entry.view else { session = nil; return }
        let at = pointer[ObjectIdentifier(s.window)].map { s.window.convert($0, to: view) } ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        s.entry.handler(phase, s.travel, at)
    }

    private func schedule(after seconds: Double) {
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.finish() } }
        ending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func finish() {
        ending?.cancel(); ending = nil
        guard session != nil else { return }
        deliver(.ended)
        session = nil
    }
}

#if DEBUG
extension MacScrollMonitor {
    /// `--mac-drive`'s `pointer.picture`: the scroll's pointer put at the middle of the picture that takes a
    /// scroll (the last registered view that is shown), for events posted to the process, which carry no
    /// window and are never hovered.
    func debugAimAtPicture() {
        for entry in entries.reversed() {
            guard let view = entry.view, let window = view.window, !view.isHidden else { continue }
            let mid = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: window)
            guard entry.accepts(window.convert(mid, to: view)) else { continue }
            debugAim(at: mid, in: window)
            return
        }
        NSLog("macscroll aim: no picture takes a scroll")
    }

    /// The scroll's pointer at `p` in `window`'s points.
    func debugAim(at p: CGPoint, in window: UIWindow) {
        watchPointer(in: window)
        pointer[ObjectIdentifier(window)] = p
        pointerWindow = window
        NSLog("macscroll aim %.0f,%.0f", p.x, p.y)
    }
}

extension MacWheelRows {
    /// `--mac-drive`'s `pointer.row`: the scroll's pointer on the first card row shown.
    func debugAimAtRow() {
        for w in probes {
            guard let p = w.probe, let window = p.window, let scroll = p.scrollView, scroll.window != nil else { continue }
            let mid = scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: window)
            NSLog("macscroll row offset %.0f of %.0f", scroll.contentOffset.x, scroll.contentSize.width)
            MacScrollMonitor.shared.debugAim(at: mid, in: window)
            return
        }
        NSLog("macscroll aim: no row")
    }
}

extension MacScrollZoom {
    /// `--log-scroll`: every scroll event a picture takes, and the zoom it made, in the log (checks only).
    static let logs = CommandLine.arguments.contains("--log-scroll")
    static func name(_ s: UIGestureRecognizer.State) -> String {
        switch s {
        case .began: "began"
        case .changed: "changed"
        case .ended: "ended"
        case .cancelled: "cancelled"
        case .failed: "failed"
        default: "other"
        }
    }
}
#endif

extension View {
    /// Mac only: a wheel or a two-finger scroll over this view, as `MacScrollZoom` tells it.
    func macScrollZoom(_ onScroll: @escaping (MacScrollZoom.Phase, CGFloat, CGPoint) -> Void) -> some View {
        background(MacScrollZoom(onScroll: onScroll))
    }
}
