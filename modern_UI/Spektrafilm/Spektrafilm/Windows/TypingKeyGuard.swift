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
//  Deliberately left to the menu: anything with ⌘ or ⌃ except ⌘A, ⌘Z and
//  ⇧⌘Z (⌘E still exports), and Return, Enter, Esc and Tab, which are how a
//  field is committed, cancelled or left — the default button on the export
//  page must still answer Return.
//
//  ⌘Z and ⇧⌘Z go to a field that has typing to undo or redo, for the same
//  reason as the arrows: the Edit menu's Undo is the app's (the grade's and
//  the sidecar's history, `Session.undoLatest`), and AppKit asks it first, so
//  a typo in a value field undid the last slider drag instead of the typo. A
//  field with nothing to undo leaves the key to the menu.
//
//  A Post-Dev control that has keyboard focus is not a text view, and its
//  arrows are not typing — but they are its own, and the Frame menu's ←/→
//  would take them first the same way. Such a control registers itself in
//  `Layer2KeyFocus` while it has focus, and the arrows go to it.

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
              let text = window.firstResponder as? NSTextView, text.isSelectable else {
            // Not typing: a focused Post-Dev control may still own the arrows —
            // unless the canvas has been clicked since, which makes it first
            // responder (`CanvasNSView.mouseDown`). The arrows are the frame's
            // then, whatever SwiftUI's focus has or has not caught up with.
            if (event.window ?? NSApp.keyWindow)?.firstResponder is CanvasNSView {
                Layer2KeyFocus.shared.releaseAll()
                return false
            }
            return Layer2KeyFocus.shared.route(event)
        }
        // Select All belongs to text even when the photo command is enabled.
        if isSelectAll(event) {
            text.selectAll(nil)
            return true
        }
        // Undo and Redo belong to the field while it has typing to take back.
        if text.isEditable, let undo = undoDirection(event), let manager = text.undoManager {
            switch undo {
            case .undo where manager.canUndo: manager.undo(); return true
            case .redo where manager.canRedo: manager.redo(); return true
            default: return false
            }
        }
        guard text.isEditable,
              belongsToText(modifiers: event.modifierFlags,
                            characters: event.charactersIgnoringModifiers)
        else { return false }
        text.keyDown(with: event)
        return true
    }

    enum UndoDirection { case undo, redo }

    /// ⌘Z or ⇧⌘Z, and nothing else (no ⌃, no ⌥).
    static func undoDirection(_ event: NSEvent) -> UndoDirection? {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard event.charactersIgnoringModifiers?.lowercased() == "z" else { return nil }
        if modifiers == .command { return .undo }
        if modifiers == [.command, .shift] { return .redo }
        return nil
    }

    private static func isSelectAll(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "a"
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

/// The Post-Dev control that has keyboard focus, if any, and what it does
/// with an arrow (see the note at the top of the file). One at a time:
/// claiming replaces the last owner.
@MainActor
final class Layer2KeyFocus {
    static let shared = Layer2KeyFocus()

    enum Arrow { case left, right, up, down
        /// +1 for right and up, −1 for left and down.
        var sign: Double { self == .right || self == .up ? 1 : -1 }
    }

    private var owner: (id: UUID, handle: (Arrow, NSEvent.ModifierFlags) -> Void)?

    var hasOwner: Bool { owner != nil }

    func claim(_ id: UUID, handle: @escaping (Arrow, NSEvent.ModifierFlags) -> Void) {
        owner = (id, handle)
    }

    /// Only the owner can let go: a row losing focus after another took it
    /// must not take the other's away.
    func release(_ id: UUID) {
        if owner?.id == id { owner = nil }
    }

    /// Whoever had them, the arrows are nobody's now (the canvas was clicked).
    func releaseAll() { owner = nil }

    /// An arrow with no ⌘ or ⌃, while a control has focus: that control's.
    func route(_ event: NSEvent) -> Bool {
        guard let owner, let arrow = Self.arrow(event) else { return false }
        owner.handle(arrow, event.modifierFlags)
        return true
    }

    static func arrow(_ event: NSEvent) -> Arrow? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control]).isEmpty,
              let key = event.charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
        switch Int(key.value) {
        case NSLeftArrowFunctionKey: return .left
        case NSRightArrowFunctionKey: return .right
        case NSUpArrowFunctionKey: return .up
        case NSDownArrowFunctionKey: return .down
        default: return nil
        }
    }

    /// The size of one press: `step`, a tenth of it with ⌥, ten of it with ⇧.
    static func stride(_ step: Double, _ modifiers: NSEvent.ModifierFlags) -> Double {
        if modifiers.contains(.option) { return step / 10 }
        if modifiers.contains(.shift) { return step * 10 }
        return step
    }
}
