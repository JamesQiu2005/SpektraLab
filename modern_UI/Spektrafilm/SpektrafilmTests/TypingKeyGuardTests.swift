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

    private func harness() throws -> (Target, NSWindow, NSTextField) {
        let app = NSApplication.shared
        let previousMenu = app.mainMenu
        let target = Target()
        let menu = NSMenu(), top = NSMenuItem(), sub = NSMenu(title: "Image")
        top.submenu = sub
        menu.addItem(top)
        let item = NSMenuItem(title: "Next Frame", action: #selector(Target.act(_:)),
                              keyEquivalent: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        item.keyEquivalentModifierMask = []
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
