//  TypingKeyGuard.swift — while something is being typed into, typing keys
//  are typing.
//
//  The app follows Capture One's single-key shortcuts: V, H and C pick a
//  tool, ←/→ step frames, `,` and `.` zoom, Y compares. They are menu items,
//  and AppKit offers a key to the menu *before* the text field that has
//  focus. Measured 2026-09-26 with a bare NSMenu and an NSTextField: a
//  modifier-free ← on an enabled menu item fired the item and never reached
//  the field — so renaming a recipe and pressing ← to move the caret stepped
//  to the next photograph instead. A plain letter happened to reach the field
//  in that experiment, but nothing in AppKit promises it, and SwiftUI builds
//  its own menu items; the guard covers both rather than trusting either.
//
//  The fix is a local monitor, which runs before the menu is asked: when the
//  key window's first responder is an editable text view and the key is one
//  that *means something to text* — characters, arrows, delete — the event
//  goes straight to the text view and the menu never sees it.
//
//  Deliberately left to the menu: anything with ⌘ or ⌃ (⌘Z in a field is
//  still Undo, ⌘E still exports), and Return, Enter, Esc and Tab, which are
//  how a field is committed, cancelled or left — the default button on the
//  export page must still answer Return.

import AppKit

enum TypingKeyGuard {
    /// Install once, at launch. The token is the monitor; keep it alive.
    @MainActor
    static func install() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            route(event) ? nil : event
        }
    }

    /// Hand `event` to the text view being typed into, if there is one and
    /// the key belongs to it. Returns whether it was handed over.
    @MainActor
    static func route(_ event: NSEvent) -> Bool {
        guard let window = event.window ?? NSApp.keyWindow,
              let text = window.firstResponder as? NSTextView, text.isEditable,
              belongsToText(modifiers: event.modifierFlags,
                            characters: event.charactersIgnoringModifiers)
        else { return false }
        text.keyDown(with: event)
        return true
    }

    /// The pure decision, separate so it is testable without an event.
    static func belongsToText(modifiers: NSEvent.ModifierFlags, characters: String?) -> Bool {
        // Shift and Option type characters; the arrow keys arrive carrying
        // `.function` and `.numericPad`. Only ⌘ and ⌃ make a key a command.
        let commandLike = modifiers.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control])
        guard commandLike.isEmpty, let key = characters?.unicodeScalars.first else { return false }
        switch key.value {
        case 0x0D, 0x03, 0x1B, 0x09, 0x19:   // Return, Enter, Esc, Tab, ⇧Tab
            return false
        default:
            return true
        }
    }
}
