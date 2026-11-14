//  CoexistingDrag.swift — a drag a scroll view may run beside.
//
//  Built with the the operating system 26 SDK, SwiftUI's `simultaneousGesture` is no longer simultaneous
//  with an ancestor's gesture: Apple's release note calls the old behaviour the bug
//  (147970990), and the change took the Develop page's scrolling with it. On the host a
//  finger dragging on a slider, a ruler or the curve was swallowed whole and the panel
//  would not move — while on this Mac a scroll wheel never meets a gesture at all, so
//  every panel looked fine there (the owner, 2026-10-15: "every subpage of them cannot
//  be scrolled on real device"). Apple's advice on the report of it (FB18199844) is a
//  UIKit recogniser rather than a SwiftUI gesture: a zero-delay, unbounded
//  `UILongPressGestureRecognizer` whose delegate allows simultaneous recognition, which
//  the scroll view's pan then obeys.
//
//  `dragBesideScroll` is that recogniser. `onChanged` receives the drag from where it
//  began — the shape the callers already kept for `DragGesture`, in the control's own points — whether it is a
//  pointer's (the Mac's mouse or trackpad) or a finger's, and the keys held; `beginsOn` may
//  refuse a touch by where it starts: the curve takes a finger only in point mode, and
//  every other finger scrolls the panel.
//
//  the operating system 17 fallback: the old `simultaneousGesture`, kept only for a device too old to run
//  `UIGestureRecognizerRepresentable` (the operating system 18). There the panels block again — no such
//  device is in the beta.

import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The drag's life as the callers knew it from `DragGesture`.
struct CoexistingDragValue {
    var start: CGPoint
    var location: CGPoint
    var translation: CGSize
    /// When the system received the pointer event this value is of (`UIEvent.timestamp`, the uptime clock that
    /// `CACurrentMediaTime` reads); nil where it is not known.
    var eventTime: TimeInterval? = nil
    /// A mouse or a trackpad's pointer (`UITouch.TouchType.indirectPointer`), not a finger: on the Mac a pointer's
    /// drag is never a scroll (a scroll is the wheel's), so a control may take it from the first point.
    var pointer = false
    /// The keys held (⇧ ⌥ ⌘) as the event came: a number box's drag is coarse or fine by them.
    var modifiers: UIKeyModifierFlags = []
}

/// The press, keeping each event's time and what kind of touch it is (a delegate sees only the first).
final class TimedPress: UILongPressGestureRecognizer {
    private(set) var eventTime: TimeInterval?
    private(set) var pointer = false
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        eventTime = event.timestamp
        pointer = touches.first?.type == .indirectPointer
        super.touchesBegan(touches, with: event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        eventTime = event.timestamp
        super.touchesMoved(touches, with: event)
    }
}

@available(iOS 18.0, *)
struct CoexistingDrag: UIGestureRecognizerRepresentable {
    var beginsOn: ((CGPoint) -> Bool)?
    var onChanged: (CoexistingDragValue) -> Void
    var onEnded: (CoexistingDragValue) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var beginsOn: ((CGPoint) -> Bool)?
        var start: CGPoint?
        /// The recogniser's view is the hosting view, not the control: its points are the window's (measured
        /// 2026-11-11: a press 96.5 pt into a slider's track read 265.7 there). The converter's are the control's
        /// own, which a caller that reads `location` — where on the track — needs.
        let converter: CoordinateSpaceConverter
        init(converter: CoordinateSpaceConverter) { self.converter = converter }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let beginsOn else { return true }
            return beginsOn(converter.localLocation)
        }

        /// The whole point: the scroll view's pan keeps working beside this.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator(converter: converter) }

    func makeUIGestureRecognizer(context: Context) -> TimedPress {
        let recognizer = TimedPress()
        recognizer.minimumPressDuration = 0
        recognizer.allowableMovement = .greatestFiniteMagnitude
        recognizer.delegate = context.coordinator
        recognizer.cancelsTouchesInView = false
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: TimedPress, context: Context) {
        context.coordinator.beginsOn = beginsOn
    }

    func handleUIGestureRecognizerAction(_ recognizer: TimedPress, context: Context) {
        let at = context.converter.localLocation
        switch recognizer.state {
        case .began:
            context.coordinator.start = at
            onChanged(value(at: at, from: at, of: recognizer))
        case .changed:
            guard let start = context.coordinator.start else { return }
            onChanged(value(at: at, from: start, of: recognizer))
        case .ended, .cancelled, .failed:
            let start = context.coordinator.start ?? at
            context.coordinator.start = nil
            onEnded(value(at: at, from: start, of: recognizer))
        default:
            break
        }
    }

    private func value(at: CGPoint, from start: CGPoint, of recognizer: TimedPress) -> CoexistingDragValue {
        CoexistingDragValue(start: start, location: at,
                            translation: CGSize(width: at.x - start.x, height: at.y - start.y),
                            eventTime: recognizer.eventTime, pointer: recognizer.pointer, modifiers: recognizer.modifierFlags)
    }
}

extension View {
    /// The drag above; on the operating system 17 the `simultaneousGesture` this replaces.
    func dragBesideScroll(beginsOn: ((CGPoint) -> Bool)? = nil,
                          onChanged: @escaping (CoexistingDragValue) -> Void,
                          onEnded: @escaping () -> Void = {}) -> some View {
        dragBesideScroll(beginsOn: beginsOn, onChanged: onChanged, onEnd: { _ in onEnded() })
    }

    /// The same, told at the end how the drag ended (where, and whether it was a pointer's).
    @ViewBuilder
    func dragBesideScroll(beginsOn: ((CGPoint) -> Bool)? = nil,
                          onChanged: @escaping (CoexistingDragValue) -> Void,
                          onEnd: @escaping (CoexistingDragValue) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            gesture(CoexistingDrag(beginsOn: beginsOn, onChanged: onChanged, onEnded: onEnd))
        } else {
            simultaneousGesture(DragGesture(minimumDistance: 8)
                .onChanged { v in onChanged(CoexistingDragValue(start: v.startLocation, location: v.location,
                                                                translation: v.translation)) }
                .onEnded { v in onEnd(CoexistingDragValue(start: v.startLocation, location: v.location,
                                                          translation: v.translation)) })
        }
    }
}
