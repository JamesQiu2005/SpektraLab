//  DevelopMenuCommands.swift — Undo and Redo in the window's menu bar, for the develop page (PAGES.md §6).
//
//  the operating system 26 puts a menu bar over every app, and its Edit menu owns ⌘Z and ⇧⌘Z: a page's own button
//  with that shortcut is never reached (the tour of 2026-10-20: ⌘Z on the develop page did nothing,
//  where ⌘B and the arrow keys, drawn the same way, did their work). So the develop page tells the
//  scene what Undo and Redo mean while it is in front (`padEditActions`, a focused scene value), and
//  `DevelopMenuCommands` replaces the Edit menu's Undo and Redo with the page's session's — the same
//  steps as its ··· menu's. Where no develop page is in front they are the system's, sent down the
//  responder chain as before (a text field's own undo).
//
//  The items are never greyed: the menu bar validated a greyed item against the page as it was a key
//  press earlier (the tour: the first ⌘Z after an edit did nothing, the next one undid it), and the
//  session's own undo and redo do nothing where there is nothing to take back.
//
//  The scene adds them: `.commands { DevelopMenuCommands() }` on the app's WindowGroup.

import SwiftUI
import UIKit

/// What Undo and Redo do on the page in front.
struct UndoRedoActions {
    var canUndo: Bool
    var canRedo: Bool
    var undo: () -> Void
    var redo: () -> Void
}

private struct UndoRedoFocusKey: FocusedValueKey {
    typealias Value = UndoRedoActions
}

extension FocusedValues {
    var padEditActions: UndoRedoActions? {
        get { self[UndoRedoFocusKey.self] }
        set { self[UndoRedoFocusKey.self] = newValue }
    }
}

/// The develop page in front, as it last appeared: what Undo and Redo reach where the scene has no
/// focused value to give (the tour: the first ⌘Z after a launch found none, and fell to the system).
@MainActor
enum UndoRedoRecipient {
    static weak var session: OpenFrameSession?
}

struct DevelopMenuCommands: Commands {
    @FocusedValue(\.padEditActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(L("Undo")) {
                if MacKeyFocus.editingField != nil { Self.send("undo:"); return }
                // Mac: a crop page or a film-edge flow over the page walks its own steps (MacFlowBar.swift).
                if let flow = MacFlowUndo.front { flow.undo(); return }
                if let actions { actions.undo() }
                else if let session = UndoRedoRecipient.session { session.undo() }
                else { Self.send("undo:") }
            }
            .keyboardShortcut("z", modifiers: .command)
            Button(L("Redo")) {
                if MacKeyFocus.editingField != nil { Self.send("redo:"); return }
                if let flow = MacFlowUndo.front { flow.redo(); return }
                if let actions { actions.redo() }
                else if let session = UndoRedoRecipient.session { session.redo() }
                else { Self.send("redo:") }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }

    /// The system's own Undo or Redo, down the responder chain, where no develop page is in front.
    @MainActor private static func send(_ action: String) {
        UIApplication.shared.sendAction(Selector(action), to: nil, from: nil, for: nil)
    }
}
