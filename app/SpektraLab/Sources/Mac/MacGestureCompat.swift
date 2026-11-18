//  MacGestureCompat.swift — the Mac's clicks, marquees and presses on macOS 14 (2.4.2).
//
//  The Mac's pointer gestures are UIKit recognisers through `UIGestureRecognizerRepresentable`, which is Mac
//  Catalyst 18 (macOS 15) and later: they read the event's own modifier keys (`modifierFlags`) and run beside the
//  scroll views. 2.4.2 runs on macOS 14 as well, where that API is not there. There each is SwiftUI's own gesture of the
//  same shape, as the iPad's iOS 17 fallback is (`CoexistingDrag`): a pointer on the Mac never meets a scroll the way a
//  finger does (the wheel scrolls), so a SwiftUI gesture there blocks nothing. The keys a click is made with are read
//  from AppKit's `NSEvent.modifierFlags` (the keys held now, which on a click are the click's), through the Objective-C
//  runtime as the app reaches AppKit elsewhere; its bits are UIKit's.
//
//  What macOS 14 does not have: a click away from a field does not end its editing (`MacEndEditingOnClick`) — Return,
//  Esc and Tab still do.
//
//  `SPEKTRALAB_LEGACY_GESTURES=1` takes the macOS 14 path on a newer Mac, so it can be seen working here.

import SwiftUI
import UIKit

enum MacGestureCompat {
    /// The macOS 14 path, asked for on a newer Mac (a check's, a developer's).
    static let forcedLegacy = ProcessInfo.processInfo.environment["SPEKTRALAB_LEGACY_GESTURES"] == "1"

    /// The modifier keys held now (AppKit's `NSEvent.modifierFlags`; ⇧ ⌃ ⌥ ⌘ are the same bits as UIKit's).
    static var modifiers: UIKeyModifierFlags {
        guard let event = NSClassFromString("NSEvent") as? NSObject.Type,
              let flags = event.value(forKey: "modifierFlags") as? UInt else { return [] }
        let keep: UIKeyModifierFlags = [.alphaShift, .shift, .control, .alternate, .command, .numericPad]
        return UIKeyModifierFlags(rawValue: Int(flags)).intersection(keep)
    }
}

/// A press held and moved, as a recogniser's states: `.began` at the first event, `.changed`, `.ended`.
private struct LegacyPress: ViewModifier {
    let minimumDistance: CGFloat
    let action: (UIGestureRecognizer.State, (now: CGPoint, start: CGPoint), UIKeyModifierFlags) -> Void
    @State private var active = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: minimumDistance, coordinateSpace: .local)
                .onChanged { value in
                    let state: UIGestureRecognizer.State = active ? .changed : .began
                    active = true
                    action(state, (value.location, value.startLocation), MacGestureCompat.modifiers)
                }
                .onEnded { value in
                    active = false
                    action(.ended, (value.location, value.startLocation), MacGestureCompat.modifiers)
                }
        )
    }
}

extension View {
    /// A click on this view, with the modifier keys it was made with (`MacClick`).
    @ViewBuilder func macClick(_ action: @escaping (UIKeyModifierFlags) -> Void) -> some View {
        if #available(iOS 18.0, *), !MacGestureCompat.forcedLegacy {
            gesture(MacClickRecognizer(action: action))
        } else {
            onTapGesture { action(MacGestureCompat.modifiers) }
        }
    }

    /// A click and where it landed, in the view's own space, with the modifier keys.
    @ViewBuilder func macClickAt(_ action: @escaping (CGPoint, UIKeyModifierFlags) -> Void) -> some View {
        if #available(iOS 18.0, *), !MacGestureCompat.forcedLegacy {
            gesture(MacClickAtRecognizer(action: action))
        } else {
            gesture(SpatialTapGesture(coordinateSpace: .local).onEnded { action($0.location, MacGestureCompat.modifiers) })
        }
    }

    /// A click and where it landed, in the view's own space, beside a click a subview takes (`MacEmptyClick`).
    @ViewBuilder func macPointClick(_ action: @escaping (CGPoint) -> Void) -> some View {
        if #available(iOS 18.0, *), !MacGestureCompat.forcedLegacy {
            gesture(MacPointClickRecognizer(action: action))
        } else {
            simultaneousGesture(SpatialTapGesture(coordinateSpace: .local).onEnded { action($0.location) })
        }
    }

    /// A mouse or trackpad drag: where it is and where it began, in the view's own space, with the keys
    /// (`MacMarqueeRecognizer`).
    @ViewBuilder func macMarquee(_ action: @escaping (UIGestureRecognizer.State, (now: CGPoint, start: CGPoint), UIKeyModifierFlags) -> Void) -> some View {
        if #available(iOS 18.0, *), !MacGestureCompat.forcedLegacy {
            gesture(MacMarqueeRecognizer(action: action))
        } else {
            modifier(LegacyPress(minimumDistance: 3, action: action))
        }
    }

    /// A press from its first moment, held and moved: where it is, in the view's own space, with the keys.
    @ViewBuilder func macPress(_ action: @escaping (UIGestureRecognizer.State, CGPoint, UIKeyModifierFlags) -> Void) -> some View {
        if #available(iOS 18.0, *), !MacGestureCompat.forcedLegacy {
            gesture(MacPressRecognizer(action: action))
        } else {
            modifier(LegacyPress(minimumDistance: 0) { state, at, flags in action(state, at.now, flags) })
        }
    }
}

/// A mouse press held and moved, from its first moment: where it is, in the view's own space, and the modifier keys
/// (the event's own). The colour wheel's (`MacColourWheel`).
@available(iOS 18.0, *)
struct MacPressRecognizer: UIGestureRecognizerRepresentable {
    let action: (UIGestureRecognizer.State, CGPoint, UIKeyModifierFlags) -> Void
    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer()
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        return press
    }
    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        action(recognizer.state, context.converter.localLocation, recognizer.modifierFlags)
    }
}

/// A click and where it landed, in the view's own space, with the modifier keys (the event's own): the import page's
/// cell, whose check box's corner is the box's (`MacImportCheckBox.hit`).
@available(iOS 18.0, *)
struct MacClickAtRecognizer: UIGestureRecognizerRepresentable {
    let action: (CGPoint, UIKeyModifierFlags) -> Void
    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer { UITapGestureRecognizer() }
    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        if recognizer.state == .ended { action(context.converter.localLocation, recognizer.modifierFlags) }
    }
}
