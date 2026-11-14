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
//  *Edit History…* follows them, with no key (PRD-F §4): the history page of the picture in front.
//
//  The scene adds them: `.commands { DevelopMenuCommands(model: model) }` on the app's WindowGroup.

import SwiftUI
import UIKit

/// What Undo and Redo do on the page in front. No "can undo": the items are never greyed (above), and a value that
/// changed with Undo's state made the scene hand the commands a new value at every drag's press and lift, and AppKit
/// rebuild the whole menu bar each time (2.4.0 A2: ~20 ms of a brush's press, by `sample`).
struct UndoRedoActions {
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
    /// The app, for *Edit History…*'s page.
    let model: AppServices

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
            // 编辑历史 (PRD-F §4) under Undo and Redo, with no key: ⌥⌘H is Hide Others. The picture on the develop
            // page in front, else the one picture chosen in the browser; nothing where there is neither, or where the
            // page is up already.
            Button(L("Edit History…")) {
                guard let id = Self.historyFrame(model), model.router.sheets.last != .history(id) else { return }
                model.router.present(.history(id))
            }
        }
    }

    /// The frame *Edit History…* is about.
    @MainActor static func historyFrame(_ model: AppServices) -> LibraryFrame.ID? {
        if let session = UndoRedoRecipient.session, model.openSession(session.frameID) === session { return session.frameID }
        let rows = MacLibraryUI.store(model).images.filter { MacLibraryBrowser.shared.selection.contains($0.id) }
        guard rows.count == 1, let id = rows[0].develop?.frameID, model.library.frame(id) != nil else { return nil }
        return id
    }

    /// The system's own Undo or Redo, down the responder chain, where no develop page is in front.
    @MainActor private static func send(_ action: String) {
        UIApplication.shared.sendAction(Selector(action), to: nil, from: nil, for: nil)
    }
}
