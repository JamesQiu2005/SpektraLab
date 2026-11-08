//  MacEditCommands.swift — the Mac's Edit menu: Cut, Copy, Paste, Delete, Select All, where ⌘C and ⌘V are
//  Copy and Paste Settings unless a field has the keys (the owner, 2026-11-05: "cmd + c would enter the
//  current copy settings clipboard, and cmd + v would paste the settings").
//
//  Why the group is replaced and not left to the responder chain, as Select All was (`MacKeyAnchor`):
//  measured 2026-11-05 (`--clipboard-check`), with 冲洗 in front the develop page's SwiftUI host is the
//  first responder (`PadDevelopPage` is `.focusable`), and Edit's `paste:` climbs from it through
//  SwiftUI's views, the window, `SwiftUIApplication` and SwiftUI's own `AppDelegate` — never this app's
//  `AppDelegate` (the adaptor's object is not in the chain) — answered by none of them, so the menu item
//  was dead and ⌘V did nothing there. In 图库 the window's `MacKeyAnchor` is first and was reached. The
//  same shape as Undo's (`DevelopMenuCommands`): the menu's item decides at the press —
//
//  1. an AppKit window in front (the save panel of New Catalog…, an open panel, an alert's field) or an
//     AppKit field editor typing: AppKit's own nil-targeted action, as the system's item sent it
//     (`MacAppKitEdit`), and never the settings (the review, 2026-11-05: a SwiftUI item's closure is no
//     action AppKit walks a chain with, so ⌘V there could have pasted the settings onto the pictures
//     chosen behind the panel). Measured 2026-11-05 (`panel.windows`, `panel.paste`): the scene's window
//     is a `UINSWindow`, the save panel an `NSSavePanel` whose first responder is an `NSRemoteView` — its
//     field lives in another process, and from that view up nothing in this one takes paste: or
//     selectAll:, the system's item no more than this one; its field must take ⌘V as keys forwarded by
//     the remote view, which AppKit offers the key window before the menu. Not seen end to end: that
//     run's session was locked, so no window of it could be key;
//  2. a field being edited (`MacShortcutRegistry.typing`: a text field or view, a numeric field
//     committing, a search), or a selection that can be copied (`copiesSelection`: selectable text):
//     the system's own action down UIKit's chain, so its ⌘C, ⌘V, ⌘X and ⌘A are what they always were;
//  3. with none, the shell's registration on that key (`MacKeySpec.standard`); with no registration,
//     the chain again.
//
//  The items are never greyed, as Undo's are not: the menu validated a greyed item against the page as
//  it was a key press earlier.

import SwiftUI
import UIKit
import ObjectiveC

struct MacEditCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button(L("Cut")) { Self.send(#selector(UIResponder.cut(_:))) }
                .keyboardShortcut("x", modifiers: .command)
            Button(L("Copy")) { Self.edit(#selector(UIResponder.copy(_:))) }
                .keyboardShortcut("c", modifiers: .command)
            Button(L("Paste")) { Self.edit(#selector(UIResponder.paste(_:))) }
                .keyboardShortcut("v", modifiers: .command)
            Button(L("Paste and Match Style")) { Self.send(#selector(UIResponder.pasteAndMatchStyle(_:))) }
                .keyboardShortcut("v", modifiers: [.command, .option, .shift])
            Button(L("Delete")) { Self.send(#selector(UIResponder.delete(_:))) }
            Button(L("Select All")) { Self.edit(#selector(UIResponder.selectAll(_:))) }
                .keyboardShortcut("a", modifiers: .command)
        }
    }

    /// Edit's `action` as the Mac means it now (the four steps above). Whether anything took it.
    @MainActor @discardableResult static func edit(_ action: Selector) -> Bool {
        if MacAppKitEdit.owns { trace(action, "appkit"); return MacAppKitEdit.send(action) }
        let registry = MacShortcutRegistry.shared
        if !registry.typing, !copiesSelection(action), registry.canPerformStandard(action) {
            trace(action, "registry")
            registry.performStandard(action)
            return true
        }
        trace(action, "chain")
        return send(action)
    }

    /// `--key-trace`: where an Edit action went.
    private static func trace(_ action: Selector, _ way: String) {
        #if DEBUG
        if CommandLine.arguments.contains("--key-trace") { NSLog("[edit] %@ → %@", NSStringFromSelector(action), way) }
        #endif
    }

    /// The system's own action: AppKit's, when an AppKit window or field editor has the keys; otherwise
    /// down UIKit's responder chain from the first responder (a field's).
    @MainActor @discardableResult static func send(_ action: Selector) -> Bool {
        if MacAppKitEdit.owns { return MacAppKitEdit.send(action) }
        return UIApplication.shared.sendAction(action, to: nil, from: nil, for: nil)
    }

    /// Copy with something selected that copies (the review, 2026-11-05: a path selected in Info's rows,
    /// `.textSelection(.enabled)`): a responder in the chain other than the window's anchor that says it
    /// can copy. The anchor says yes for the registry, so it is not asked.
    @MainActor static func copiesSelection(_ action: Selector) -> Bool {
        guard action == #selector(UIResponder.copy(_:)) else { return false }
        return copier != nil
    }

    /// The first responder in the chain, other than the anchor, that can copy now. Text (SwiftUI's
    /// selectable `Text` is a `TextSelectionInteractionView` on Catalyst, a `UITextInput`; measured
    /// 2026-11-05) counts only with something selected: it says it can copy with nothing selected too.
    @MainActor static var copier: UIResponder? {
        var r = UIResponder.spkFirstResponder
        var steps = 0
        while let here = r, steps < 64 {
            if !(here is MacKeyAnchor), here.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil) {
                guard let text = here as? UITextInput else { return here }
                if let range = text.selectedTextRange, !range.isEmpty { return here }
            }
            r = here.next
            steps += 1
        }
        return nil
    }
}

/// AppKit's side of the Edit menu, through the runtime as `MacSavePanel` reaches `NSSavePanel`: whether
/// AppKit has the keys, and its own nil-targeted action for when it does.
@MainActor
enum MacAppKitEdit {
    private static var app: NSObject? {
        guard let cls: AnyClass = NSClassFromString("NSApplication") else { return nil }
        return (cls as AnyObject).value(forKey: "sharedApplication") as? NSObject
    }

    /// The key window is not a UIKit scene's (`UINSWindow`: the save and open panels, an alert), or it
    /// is and an AppKit field editor (`NSText`) is its first responder. False with no key window (the app
    /// in the background), where nothing AppKit's could be typing.
    static var owns: Bool { owns(app?.value(forKey: "keyWindow") as? NSObject) }

    /// Whether AppKit has the keys when `window` is the key window (the rule above, for any window).
    static func owns(_ window: NSObject?) -> Bool {
        guard let window else { return false }
        guard let scene: AnyClass = NSClassFromString("UINSWindow"), window.isKind(of: scene) else { return true }
        guard let text: AnyClass = NSClassFromString("NSText"),
              let first = window.value(forKey: "firstResponder") as? NSObject else { return false }
        return first.isKind(of: text)
    }

    /// `-[NSApplication sendAction:to:from:]` with no target: the key window's first responder and up,
    /// as the system's Edit items send theirs. Whether anything took it. Never with a target: one that
    /// does not answer the action raises (an unrecognised selector ended a debug run, 2026-11-05).
    @discardableResult static func send(_ action: Selector) -> Bool {
        guard let app else { return false }
        let sel = NSSelectorFromString("sendAction:to:from:")
        guard let method = class_getInstanceMethod(type(of: app), sel) else { return false }
        typealias Send = @convention(c) (NSObject, Selector, Selector, AnyObject?, AnyObject?) -> Bool
        let call = unsafeBitCast(method_getImplementation(method), to: Send.self)
        return call(app, sel, action, nil, nil)
    }

    /// The event being handled is a key held down repeating (`-[NSEvent isARepeat]`, asked of a key
    /// event only: AppKit raises for any other). A menu's key equivalent fires on each repeat, so ⌘V held
    /// for a moment would paste again and again.
    static var isKeyRepeat: Bool {
        guard let event = app?.value(forKey: "currentEvent") as? NSObject,
              let type = (event.value(forKey: "type") as? NSNumber)?.intValue,
              type == 10 || type == 11 else { return false }        // NSEventTypeKeyDown, KeyUp
        let sel = NSSelectorFromString("isARepeat")
        guard let method = class_getInstanceMethod(Swift.type(of: event), sel) else { return false }
        typealias Get = @convention(c) (NSObject, Selector) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Get.self)(event, sel)
    }

    #if DEBUG
    /// `-[NSApplication activateIgnoringOtherApps:]`, then `window` made key: a driver's way to give an
    /// AppKit panel the keys while the check's copy of the app is not in front.
    static func debugActivate(_ window: NSObject?) {
        guard let app else { return }
        let sel = NSSelectorFromString("activateIgnoringOtherApps:")
        if let method = class_getInstanceMethod(type(of: app), sel) {
            typealias Activate = @convention(c) (NSObject, Selector, Bool) -> Void
            unsafeBitCast(method_getImplementation(method), to: Activate.self)(app, sel, true)
        }
        _ = window?.perform(NSSelectorFromString("makeKeyAndOrderFront:"), with: nil)
        NSLog("[panel] activated: %@", keyWindowFacts.description)
    }

    /// Every AppKit window of the app: its class and superclasses, its first responder's, whether AppKit
    /// would have the keys were it key (`owns(_:)`).
    static var windowFacts: [String] {
        guard let windows = app?.value(forKey: "windows") as? [NSObject] else { return ["no NSApplication"] }
        return windows.map { w in
            var chain: [String] = []
            var c: AnyClass? = type(of: w)
            while let k = c, chain.count < 6 { chain.append(NSStringFromClass(k)); c = class_getSuperclass(k) }
            let first = (w.value(forKey: "firstResponder") as? NSObject).map { NSStringFromClass(type(of: $0)) } ?? "none"
            return "\(chain.joined(separator: "<")) first=\(first) visible=\((w.value(forKey: "isVisible") as? Bool) ?? false) appkit=\(owns(w))"
        }
    }

    /// What a check says of the window that has the keys: its class, and its first responder's.
    static var keyWindowFacts: [String: String] {
        guard let key = app?.value(forKey: "keyWindow") as? NSObject else { return ["key": "none"] }
        let first = key.value(forKey: "firstResponder") as? NSObject
        return ["key": String(describing: type(of: key)), "first": first.map { String(describing: type(of: $0)) } ?? "none",
                "appkit_owns": "\(owns)"]
    }
    #endif
}
