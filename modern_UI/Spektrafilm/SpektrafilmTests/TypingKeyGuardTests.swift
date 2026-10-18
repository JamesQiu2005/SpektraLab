//  TypingKeyGuardTests.swift — a key typed into a field is not a shortcut.
//
//  The integration test builds the real shape of the bug: a menu item with a
//  modifier-free ← (the app's "next frame"), a text field with focus, and a
//  key event sent through `NSApp.sendEvent` — the path a real keystroke takes,
//  menu first. Without the guard the menu item fires (measured before the
//  fix); with it, the field gets the key and the item does not.

import AppKit
import XCTest

@MainActor
final class TypingKeyGuardTests: XCTestCase {

    // MARK: - the decision

    func testTypingKeysBelongToTheText() {
        let arrow = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        let cases: [(NSEvent.ModifierFlags, String)] = [
            ([], "c"), ([], "v"), ([.shift], "M"), ([.option], "o"), ([], ","), ([], "."),
            ([.function, .numericPad], arrow), ([], "\u{7F}"),
        ]
        for (mods, key) in cases {
            XCTAssertTrue(TypingKeyGuard.belongsToText(modifiers: mods, characters: key),
                          "\(key.debugDescription) with \(mods.rawValue) should type, not trigger a shortcut")
        }
    }

    func testCommandsAndCommitKeysStayWithTheMenu() {
        let cases: [(NSEvent.ModifierFlags, String)] = [
            ([.command], "z"), ([.command], "e"), ([.control], "c"),
            ([], "\r"), ([], "\u{03}"), ([], "\u{1B}"), ([], "\t"), ([.shift], "\u{19}"),
        ]
        for (mods, key) in cases {
            XCTAssertFalse(TypingKeyGuard.belongsToText(modifiers: mods, characters: key),
                           "\(key.debugDescription) with \(mods.rawValue) must still reach the menu")
        }
        XCTAssertFalse(TypingKeyGuard.belongsToText(modifiers: [], characters: nil))
    }

    // MARK: - the real path

    private final class Target: NSObject {
        var fired = 0
        @objc func act(_ sender: Any?) { fired += 1 }
    }

    /// ← in a focused field moves the caret; it does not step the frame.
    /// **Seen red** without the monitor: the menu item fired.
    func testAnArrowInAFieldDoesNotStepTheFrame() throws {
        let (target, window, _) = try harness()
        let monitor = TypingKeyGuard.install()
        defer { monitor.map(NSEvent.removeMonitor) }
        NSApp.sendEvent(try arrowEvent(in: window))
        XCTAssertEqual(target.fired, 0, "← in a text field fired the menu's shortcut")
    }

    /// The control: the harness does reproduce the bug without the guard, so
    /// the test above is not green for want of a menu that could fire.
    func testTheHarnessReproducesTheBugWithoutTheGuard() throws {
        let (target, window, _) = try harness()
        NSApp.sendEvent(try arrowEvent(in: window))
        XCTAssertEqual(target.fired, 1, "the harness cannot fire the menu item, so it proves nothing")
    }

    /// Away from a field the shortcut is still a shortcut.
    func testTheShortcutStillWorksOutsideAField() throws {
        let (target, window, _) = try harness()
        let monitor = TypingKeyGuard.install()
        defer { monitor.map(NSEvent.removeMonitor) }
        window.makeFirstResponder(window.contentView)
        NSApp.sendEvent(try arrowEvent(in: window))
        XCTAssertEqual(target.fired, 1, "the guard swallowed a shortcut with no field focused")
    }

    func testCommandASelectsTextInsteadOfPhotos() throws {
        let (_, window, field) = try harness()
        let text = try XCTUnwrap(window.firstResponder as? NSTextView)
        text.setSelectedRange(NSRange(location: 1, length: 0))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0))
        XCTAssertTrue(TypingKeyGuard.route(event), "the photo menu would receive Command+A")
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: field.stringValue.utf16.count))
        window.makeFirstResponder(window.contentView)
        XCTAssertFalse(TypingKeyGuard.route(event), "Command+A must reach photos outside text")
    }

    /// ⌘Z in a value field with typing to take back undoes the typing, not
    /// the last slider drag. With nothing typed it is the menu's again.
    ///
    /// **Seen red** without the ⌘Z branch in `route`: the menu's Undo fired
    /// and the typing stayed.
    func testCommandZInAFieldUndoesTheTyping() throws {
        let (target, window, field) = try harness(undo: true)
        let text = try XCTUnwrap(window.firstResponder as? NSTextView)
        let monitor = TypingKeyGuard.install()
        defer { monitor.map(NSEvent.removeMonitor) }
        text.allowsUndo = true
        let manager = try XCTUnwrap(text.undoManager)
        manager.groupsByEvent = false
        text.setSelectedRange(NSRange(location: 2, length: 0))
        manager.beginUndoGrouping()
        text.insertText("c", replacementRange: NSRange(location: NSNotFound, length: 0))
        manager.endUndoGrouping()
        XCTAssertEqual(text.string, "abc")
        NSApp.sendEvent(try commandZ(in: window))
        XCTAssertEqual(target.fired, 0, "⌘Z in a field with typing fired the app's Undo")
        XCTAssertEqual(text.string, "ab", "the typing was not undone")
        // Nothing left to undo in the field: the key is the menu's.
        XCTAssertFalse(manager.canUndo)
        NSApp.sendEvent(try commandZ(in: window))
        XCTAssertEqual(target.fired, 1, "with nothing typed, ⌘Z must reach the app's Undo")
        _ = field
    }

    /// A focused Post-Dev control owns the arrows, as a field does; with no
    /// control focused the Frame menu has them.
    func testAFocusedPostDevControlTakesTheArrows() throws {
        let (target, window, _) = try harness()
        let monitor = TypingKeyGuard.install()
        defer { monitor.map(NSEvent.removeMonitor) }
        window.makeFirstResponder(window.contentView)
        var pressed: [Layer2KeyFocus.Arrow] = []
        let id = UUID()
        Layer2KeyFocus.shared.claim(id) { arrow, _ in pressed.append(arrow) }
        NSApp.sendEvent(try arrowEvent(in: window))
        Layer2KeyFocus.shared.release(id)
        XCTAssertEqual(pressed, [.left])
        XCTAssertEqual(target.fired, 0, "the Frame menu took the arrow from a focused control")
        NSApp.sendEvent(try arrowEvent(in: window))
        XCTAssertEqual(target.fired, 1, "released, the arrow is the menu's again")
    }

    private func commandZ(in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, characters: "z",
                                       charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
    }

    private func harness(undo: Bool = false) throws -> (Target, NSWindow, NSTextField) {
        let app = NSApplication.shared
        let previousMenu = app.mainMenu
        let target = Target()
        let menu = NSMenu(), top = NSMenuItem(), sub = NSMenu(title: "Image")
        top.submenu = sub
        menu.addItem(top)
        let item = undo
            ? NSMenuItem(title: "Undo", action: #selector(Target.act(_:)), keyEquivalent: "z")
            : NSMenuItem(title: "Next Frame", action: #selector(Target.act(_:)),
                         keyEquivalent: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        item.keyEquivalentModifierMask = undo ? .command : []
        item.target = target
        sub.addItem(item)
        app.mainMenu = menu

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        field.stringValue = "ab"
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        addTeardownBlock { @MainActor in
            window.close()
            app.mainMenu = previousMenu
        }
        try XCTSkipUnless(window.firstResponder is NSTextView, "no window server: the field cannot take focus")
        return (target, window, field)
    }

    private func arrowEvent(in window: NSWindow) throws -> NSEvent {
        let arrow = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                              modifierFlags: [.function, .numericPad], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil,
                                              characters: arrow, charactersIgnoringModifiers: arrow,
                                              isARepeat: false, keyCode: 123))
    }
}
