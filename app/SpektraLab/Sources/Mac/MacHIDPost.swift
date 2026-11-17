//  MacHIDPost.swift — a debug check's mouse and trackpad, in the app's own event queue (2.4.1 round 4, 2026-11-16).
//
//  The round-3 checks handed their drags and scrolls to the process from outside (`CGEvent.postToPid`), which on this
//  Mac reached no view ("UNREACHED"), so the grip and the watermark's turn handle shipped on a reading of the code and
//  both failed under the owner's hand. Moving the real pointer is not allowed either (the owner, 2026-11-16: checks stay
//  in the background and never touch the cursor, the keyboard's focus or the frontmost app). So the act is made here:
//  each event an `NSEvent` of the app's window (a mouse's move, press, drag and lift with the window's number and its
//  place in the window; a scroll from a `CGEvent` with its phase, momentum phase and precise or line deltas) **posted
//  into the app's own queue** (`NSApplication.postEvent:atStart:`). From there it takes the road a hand's does: the
//  local monitors (`MacScrollMonitor`), `sendEvent`, the window, Catalyst's bridge to UIKit, the hit-test, the hover and
//  the gesture recognisers, the scroll views' own scrolling. Only the window server's part — which window is under the
//  pointer — is skipped, and the checks name the window.
//
//  **Nothing may come to the front** (`FocusGuard`): while an act is posted, AppKit's ways to activate the app or order
//  its window front are held to nothing and counted; the frontmost application is read before and after, and an act
//  that changed it stops every act after it. Keys (`key`, 2.4.1 E1) take the same road. The real cursor never moves (the app's `NSCursor` is its own while it is
//  not frontmost). Not in a release build.

#if targetEnvironment(macCatalyst) && DEBUG
import CoreGraphics
import Foundation
import ObjectiveC
import UIKit

@MainActor
enum MacHIDPost {
    /// The key window, in which a check's points are given.
    static var window: UIWindow? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first { !$0.isHidden && $0.bounds.width > 200 } ?? windows.first
    }

    /// Why the acts stopped (an act that brought the app to the front), or nil.
    private(set) static var stopped: String?

    static func f(_ p: CGPoint) -> String { String(format: "%.1f %.1f", p.x, p.y) }

    // MARK: the acts (points in `window`'s, UIKit's)

    /// The pointer moved to `p`, from 12 points to its left, in eight steps.
    static func hover(_ p: CGPoint) async -> Bool {
        await act("hover \(f(p))") { w in
            for i in 0...8 { await mouse(5, CGPoint(x: p.x - 12 + 1.5 * CGFloat(i), y: p.y), w) }   // NSEventTypeMouseMoved
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Moved to `from`, pressed, held still `hold` seconds, `steps` drags to `to`, a rest, lifted. `from == to`: a click.
    static func drag(_ from: CGPoint, _ to: CGPoint, steps: Int = 24, hold: Double = 0) async -> Bool {
        await act("drag \(f(from)) → \(f(to)) in \(steps)\(hold > 0 ? ", held \(hold) s" : "")") { w in
            for i in 0...6 { await mouse(5, CGPoint(x: from.x - 9 + 1.5 * CGFloat(i), y: from.y), w) }
            await mouse(1, from, w)                                                    // NSEventTypeLeftMouseDown
            try? await Task.sleep(for: .milliseconds(Int(120 + hold * 1000)))
            for i in 1...max(steps, 1) {
                let t = CGFloat(i) / CGFloat(max(steps, 1))
                await mouse(6, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), w)   // LeftMouseDragged
            }
            try? await Task.sleep(for: .milliseconds(200))
            await mouse(2, to, w)                                                      // NSEventTypeLeftMouseUp
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// A key pressed and let go by its virtual `keyCode` (Space 49, → 124, ← 123, Return 36, "x" 7), as AppKit's
    /// key-down and key-up of the window, posted into the app's queue like the mouse's (2.4.1 E1). From there it goes
    /// where a hand's key goes: the window, Catalyst's bridge, UIKit's key commands (`MacKeyAnchor`'s) or the field
    /// being edited. **No characters by default**: UIKit reads the key from its code; an event that carries its
    /// text (" ", "\r") is offered to the text input system first, which in an app that is not in front takes it
    /// and hands it on to nothing (measured 2026-11-16: Space and Return with their characters never reached a key
    /// command, the arrows and both of them without did). So a field's typed text is not something this can drive.
    static func key(_ characters: String = "", keyCode: UInt16, flags: UInt = 0) async -> Bool {
        await act("key \(keyCode) \(characters.debugDescription)") { w in
            await keyEvent(10, characters, keyCode, flags, w)                          // NSEventTypeKeyDown
            await keyEvent(11, characters, keyCode, flags, w)                          // NSEventTypeKeyUp
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    enum Scroll: String { case phased, glide, momentum, wheel }

    /// At `p`: `count` events of `dy` pixels (negative: the content moves up, as two fingers pushed up with natural
    /// scrolling) — `phased` a trackpad's began, changed and ended; `glide` that and a momentum tail of `count` decaying
    /// events; `momentum` the tail alone (a smooth-scrolling mouse utility); `wheel` a plain wheel's `count` clicks of a
    /// line each, no phases.
    static func scroll(_ p: CGPoint, dy: Int, count: Int, _ kind: Scroll) async -> Bool {
        await act("scroll \(kind.rawValue) \(count) × \(dy) at \(f(p))") { w in
            for i in 0...6 { await mouse(5, CGPoint(x: p.x - 9 + 1.5 * CGFloat(i), y: p.y), w) }
            try? await Task.sleep(for: .milliseconds(100))
            func decay(_ i: Int) -> Int32 { Int32((Double(dy) * pow(0.85, Double(i))).rounded()) }
            switch kind {
            case .wheel:
                for _ in 0..<count { await wheel(p, Int32(dy < 0 ? -1 : 1), lines: true, phase: 0, momentum: 0, w); try? await Task.sleep(for: .milliseconds(60)) }
            case .momentum:
                for i in 0..<count { await wheel(p, decay(i), lines: false, phase: 0, momentum: i == 0 ? 1 : 2, w) }
                await wheel(p, 0, lines: false, phase: 0, momentum: 3, w)
            case .phased, .glide:
                await wheel(p, 0, lines: false, phase: 1, momentum: 0, w)                      // kCGScrollPhaseBegan
                for _ in 0..<count { await wheel(p, Int32(dy), lines: false, phase: 2, momentum: 0, w) }
                await wheel(p, 0, lines: false, phase: 4, momentum: 0, w)                      // Ended
                if kind == .glide {
                    for i in 0..<count { await wheel(p, decay(i + 1), lines: false, phase: 0, momentum: i == 0 ? 1 : 2, w) }
                    await wheel(p, 0, lines: false, phase: 0, momentum: 3, w)                  // kCGMomentumScrollPhaseEnd
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    // MARK: the road

    private struct Target { let ui: UIWindow; let ns: NSObject; let number: Int; let frame: CGRect }

    private static func act(_ what: String, _ body: (Target) async -> Void) async -> Bool {
        if let stopped { print("pointer: not posted (\(stopped)): \(what)"); return false }
        guard let ui = window, let ns = nsWindow(for: ui), let number = (ns.value(forKey: "windowNumber") as? NSNumber)?.intValue,
              let frame = (ns.value(forKey: "frame") as? NSValue)?.cgRectValue, frame.width > 0 else {
            print("pointer: no window to post to: \(what)"); return false
        }
        let front = frontmost()
        FocusGuard.acceptFirstMouse(in: ns)
        FocusGuard.holding = true
        await body(Target(ui: ui, ns: ns, number: number, frame: frame))
        FocusGuard.holding = false
        let after = frontmost()
        if FocusGuard.held > 0 { print("pointer: AppKit asked \(FocusGuard.held) time(s) to bring the app or its window to the front; held") }
        if after != front, after == Int(getpid()) {
            stopped = "the act brought this app to the front (frontmost pid \(front) → \(after))"
            print("pointer: STOPPED — \(stopped!)")
            return false
        }
        return true
    }

    /// The pid of the frontmost application.
    static func frontmost() -> Int {
        let workspace = (NSClassFromString("NSWorkspace") as? NSObject.Type)?.value(forKey: "sharedWorkspace") as? NSObject
        return ((workspace?.value(forKey: "frontmostApplication") as? NSObject)?.value(forKey: "processIdentifier") as? Int) ?? -1
    }

    private static var nsApp: NSObject? {
        (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject
    }

    /// AppKit's window of `ui`: the app's visible window whose frame is `ui`'s shape (Catalyst draws the window's
    /// points smaller, so by its aspect), the largest.
    private static func nsWindow(for ui: UIWindow) -> NSObject? {
        guard let all = nsApp?.value(forKey: "windows") as? [NSObject] else { return nil }
        let aspect = ui.bounds.width / max(ui.bounds.height, 1)
        return all.filter { w in
            guard (w.value(forKey: "isVisible") as? Bool) == true, let f = (w.value(forKey: "frame") as? NSValue)?.cgRectValue, f.height > 0 else { return false }
            return abs(f.width / f.height - aspect) < 0.03
        }.max { a, b in
            ((a.value(forKey: "frame") as? NSValue)?.cgRectValue.width ?? 0) < ((b.value(forKey: "frame") as? NSValue)?.cgRectValue.width ?? 0)
        }
    }

    /// `p` (the UIKit window's points) in AppKit's window coordinates: the content fills the frame, y runs up.
    private static func inWindow(_ p: CGPoint, _ t: Target) -> CGPoint {
        let k = t.frame.width / max(t.ui.bounds.width, 1)
        return CGPoint(x: p.x * k, y: t.frame.height - p.y * k)
    }

    /// The same on the screen, as Quartz has it (top left of the main display).
    private static func onScreen(_ p: CGPoint, _ t: Target) -> CGPoint {
        let w = inWindow(p, t)
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: t.frame.minX + w.x, y: mainHeight - (t.frame.minY + w.y))
    }

    private static func post(_ event: NSObject) {
        guard let app = nsApp else { return }
        let sel = NSSelectorFromString("postEvent:atStart:")
        guard let imp = class_getMethodImplementation(type(of: app), sel) else { return }
        typealias Post = @convention(c) (AnyObject, Selector, AnyObject, Bool) -> Void
        unsafeBitCast(imp, to: Post.self)(app, sel, event, false)
    }

    /// A mouse event of `type` (NSEventType) at `p`, posted, and a frame for it to be handled.
    private static func mouse(_ type: UInt, _ p: CGPoint, _ t: Target) async {
        guard let cls = NSClassFromString("NSEvent") else { return }
        let sel = NSSelectorFromString("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:")
        guard let method = class_getClassMethod(cls, sel) else { return }
        typealias Make = @convention(c) (AnyClass, Selector, UInt, CGPoint, UInt, Double, Int, AnyObject?, Int, Int, Float) -> Unmanaged<AnyObject>?
        let make = unsafeBitCast(method_getImplementation(method), to: Make.self)
        let down = type == 1 || type == 6
        guard let e = make(cls, sel, type, inWindow(p, t), 0, ProcessInfo.processInfo.systemUptime, t.number, nil, 0,
                           type == 5 ? 0 : 1, down ? 1 : 0)?.takeUnretainedValue() as? NSObject else { return }
        post(e)
        try? await Task.sleep(for: .milliseconds(16))
    }

    private static func keyEvent(_ type: UInt, _ characters: String, _ keyCode: UInt16, _ flags: UInt, _ t: Target) async {
        guard let cls = NSClassFromString("NSEvent") else { return }
        let sel = NSSelectorFromString("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:")
        guard let method = class_getClassMethod(cls, sel) else { return }
        typealias Make = @convention(c) (AnyClass, Selector, UInt, CGPoint, UInt, Double, Int, AnyObject?, NSString, NSString, Bool, UInt16) -> Unmanaged<AnyObject>?
        let make = unsafeBitCast(method_getImplementation(method), to: Make.self)
        guard let e = make(cls, sel, type, .zero, flags, ProcessInfo.processInfo.systemUptime, t.number, nil,
                           characters as NSString, characters as NSString, false, keyCode)?.takeUnretainedValue() as? NSObject else { return }
        post(e)
        try? await Task.sleep(for: .milliseconds(16))
    }

    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocation? = {
        guard let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }   // RTLD_DEFAULT
        return unsafeBitCast(f, to: SetWindowLocation.self)
    }()

    /// A scroll event, made as the window server makes one (`CGEvent`), its window named, as AppKit's `NSEvent`.
    private static func wheel(_ p: CGPoint, _ delta: Int32, lines: Bool, phase: Int64, momentum: Int64, _ t: Target) async {
        func make(_ d: Int32) -> NSObject? {
            guard let e = CGEvent(scrollWheelEvent2Source: nil, units: lines ? .line : .pixel, wheelCount: 1, wheel1: d, wheel2: 0, wheel3: 0) else { return nil }
            e.location = onScreen(p, t)
            e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(t.number))
            e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(t.number))
            // The field AppKit takes an event's window from (kCGSEventWindowIDField: the window server's own, 51).
            if let field = CGEventField(rawValue: 51) { e.setIntegerValueField(field, value: Int64(t.number)) }
            // And its place in that window (Quartz's, top left), which the window server writes for a hand's event:
            // `CGEventSetWindowLocation` (SkyLight's, exported by CoreGraphics; looked up, not linked).
            if let set = setWindowLocation {
                let w = inWindow(p, t)
                set(e, CGPoint(x: w.x, y: t.frame.height - w.y))
            }
            if !lines {
                e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            }
            guard let cls = NSClassFromString("NSEvent"), let method = class_getClassMethod(cls, NSSelectorFromString("eventWithCGEvent:")) else { return nil }
            typealias Make = @convention(c) (AnyClass, Selector, CGEvent) -> Unmanaged<AnyObject>?
            return unsafeBitCast(method_getImplementation(method), to: Make.self)(cls, NSSelectorFromString("eventWithCGEvent:"), e)?.takeUnretainedValue() as? NSObject
        }
        guard var e = make(delta) else { return }
        // A line's sign as AppKit reads it: negative is the content moving up, as a pixel's is (the system may turn a
        // wheel's lines for natural scrolling).
        if lines, let read = (e.value(forKey: "scrollingDeltaY") as? NSNumber)?.doubleValue, read != 0, (read < 0) != (delta < 0),
           let flipped = make(-delta) { e = flipped }
        post(e)
        try? await Task.sleep(for: .milliseconds(16))
    }
}

/// While an act is posted: AppKit's ways to bring this app or its window to the front do nothing, and are counted.
@MainActor
enum FocusGuard {
    static var holding = false { didSet { if holding { install() } } }
    static var held = 0
    private static var installed = false

    private static var firstMouse: Set<ObjectIdentifier> = []

    /// While an act is posted, the window's AppKit views take a click though the app is not frontmost: a window of an
    /// app in the background answers its first click by bringing the app forward and **drops it** (Catalyst asks UIKit's
    /// hit-test, which says no) — seen: the stage's `point(inside:)` asked and true, and no touch begun. A hand's click
    /// reaches a frontmost app, so the check makes the window take it as it would there.
    static func acceptFirstMouse(in window: NSObject) {
        guard let content = window.value(forKey: "contentView") as? NSObject else { return }
        var views = [content]
        while let v = views.popLast() {
            views += (v.value(forKey: "subviews") as? [NSObject]) ?? []
            let cls: AnyClass = type(of: v)
            guard !firstMouse.contains(ObjectIdentifier(cls)) else { continue }
            firstMouse.insert(ObjectIdentifier(cls))
            let sel = NSSelectorFromString("acceptsFirstMouse:")
            guard let original = class_getMethodImplementation(cls, sel) else { continue }
            let block: @convention(block) (AnyObject, AnyObject?) -> Bool = { me, event in
                if MainActor.assumeIsolated({ holding }) { return true }
                typealias Call = @convention(c) (AnyObject, Selector, AnyObject?) -> Bool
                return unsafeBitCast(original, to: Call.self)(me, sel, event)
            }
            class_replaceMethod(cls, sel, imp_implementationWithBlock(block), "B@:@")
        }
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        let swaps: [(String, String)] = [("NSApplication", "activateIgnoringOtherApps:"), ("NSApplication", "activate"),
                                        ("NSApplication", "activateWithOptions:"), ("NSWindow", "makeKeyAndOrderFront:"),
                                        ("NSWindow", "orderFront:"), ("NSWindow", "orderFrontRegardless")]
        for (c, s) in swaps {
            guard let cls = NSClassFromString(c), let m = class_getInstanceMethod(cls, NSSelectorFromString(s)) else { continue }
            let original = method_getImplementation(m)
            let sel = NSSelectorFromString(s)
            let block: @convention(block) (AnyObject, AnyObject?) -> Void = { me, arg in
                if MainActor.assumeIsolated({ holding }) {
                    MainActor.assumeIsolated { held += 1 }
                    NSLog("FocusGuard: held %@ %@", c, s)
                    return
                }
                typealias Call = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
                unsafeBitCast(original, to: Call.self)(me, sel, arg)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }
}
#endif
