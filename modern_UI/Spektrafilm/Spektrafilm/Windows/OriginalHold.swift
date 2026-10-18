//  OriginalHold.swift — press and hold for the Original, release for the edit.
//
//  **V5 (2026-10-18): the Original is a press, not a place.** Holding shows
//  the source as Apple's decoder renders it — before the film, the paper and
//  the grade — and letting go returns to the edit, the same way from every
//  door. On the desktop the doors are three:
//
//  - **the Original pill** in the top bar: pressed and held, it shows the
//    original until it is released. A short click keeps doing what the pill
//    has always done — it latches, and a second click unlatches — because a
//    latch is the one way to look at the original without holding a button,
//    which is what VoiceOver and a tremor both need (V5 asks for exactly that
//    alternative), and because the latch is what works today;
//  - **holding `\`** anywhere in the editor window, except while a field is
//    being typed into. `\` is Lightroom's before/after key, and a held key
//    leaves both hands free for the trackpad, so pan and zoom go on working
//    while the original is up;
//  - **holding Space** on the canvas, unchanged (`CanvasNSView`).
//
//  The canvas's own mouse gestures — pan, the crop handles, the split's
//  grip, a pair's holes — are not doors: a press on the picture keeps meaning
//  what it meant. Nothing here changes the open frame or an edit, so the
//  batch-export lock (trap 34) has nothing to hold; the key is refused during
//  a batch only because the editor itself is look-only then.

import AppKit
import SwiftUI

enum OriginalHold {
    /// A press at least this long is a hold; shorter is a click.
    static let holdThreshold: TimeInterval = 0.3

    /// What "showing the original" becomes when a press of the pill ends:
    /// after a hold, what it was before the press; after a click, the other.
    static func afterRelease(wasShowing: Bool, held: TimeInterval) -> Bool {
        held >= holdThreshold ? wasShowing : !wasShowing
    }
}

/// The `\` key, held. A local monitor rather than a menu item: a menu key
/// fires once on the way down and never hears the key come up.
@MainActor
enum OriginalHoldKey {
    /// The editor's window, recorded by `EditorWindowMarker`; the key does
    /// nothing in Settings or on the export page.
    weak static var editorWindow: NSWindow?
    /// Whether the original on screen is the key's to take down. A latched
    /// Original (the pill, clicked) is left up when the key is released.
    private(set) static var holding = false

    static func install(session: Session) -> [Any] {
        var tokens: [Any] = []
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp], handler: { event in
            handle(event, session: session) ? nil : event
        }) { tokens.append(monitor) }
        // A key that goes up while the app is not listening is never heard:
        // leaving the app ends the hold.
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { release(session) }
            })
        return tokens
    }

    /// Whether `event` is the hold key with no command-like modifier.
    static func isHoldKey(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        let commandLike = modifiers.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option])
        return commandLike.isEmpty && characters == "\\"
    }

    /// True when the event was the hold key and has been used.
    static func handle(_ event: NSEvent, session: Session) -> Bool {
        guard isHoldKey(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags),
              let window = event.window, window === editorWindow else { return false }
        // Typing a backslash into a field is typing (trap 32's rule).
        if let text = window.firstResponder as? NSTextView, text.isEditable { return false }
        if event.type == .keyDown {
            guard !event.isARepeat else { return true }
            press(session)
        } else {
            release(session)
        }
        return true
    }

    static func press(_ session: Session) {
        guard !holding, !session.batchExporting, session.selection != nil,
              !session.showingOriginal else { return }
        session.toggledOriginal(true)
        holding = session.showingOriginal
    }

    static func release(_ session: Session) {
        guard holding else { return }
        holding = false
        session.toggledOriginal(false)
    }
}

/// Records the editor's `NSWindow` for `OriginalHoldKey`.
struct EditorWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Marker() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { OriginalHoldKey.editorWindow = window }
        }
    }
}
