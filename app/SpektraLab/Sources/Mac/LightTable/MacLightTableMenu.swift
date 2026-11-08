//  MacLightTableMenu.swift — a right click on a film on the Mac's Light Table (2026-10-24).
//
//  The owner: "the user should be able to right-click on images to rotate, take it down, but no 'change
//  format' or delete in the right-click menu." The website's film menu, without its 更改画幅… and 片边:
//
//      Rotate Right      R
//      Rotate Left      ⇧R
//      ─────────────────
//      Take Off          ⌫
//
//  - On a film only: the empty table has no menu. The film right-clicked is chosen first, as on the website;
//    a film the Click tool holds is put down where it is before its menu opens.
//  - Each item is a `UIKeyCommand`, so the Mac's menu shows its key the way the website's shows its `kbd`; the
//    same keys work on the chosen film without the menu (the page's own keys). Their actions travel the
//    responder chain to the window (`UIWindow` below), which hands them to the menu that made them.
//  - Take Off is the page's own, with its Undo (6 s, the status line's pill); nothing is deleted.

import UIKit

@MainActor
final class MacLightTableMenu: NSObject, UIContextMenuInteractionDelegate {
    /// What the page does with the film (its own functions: Take Off offers Undo).
    struct Actions {
        var rotateRight: (UUID) -> Void
        var rotateLeft: (UUID) -> Void
        var takeOff: (UUID) -> Void
    }

    private weak var view: LightTableMetalView?
    private let actions: Actions
    /// The film the menu last opened on.
    private(set) var film: UUID?
    /// The menu last made and asked to act: the window's actions go to it.
    static weak var current: MacLightTableMenu?

    init(view: LightTableMetalView, actions: Actions) {
        self.view = view
        self.actions = actions
        super.init()
        let interaction = UIContextMenuInteraction(delegate: self)
        view.addInteraction(interaction)
        view.contextMenu = self
    }

    /// The menu at a view point: nil off a film.
    func menu(at p: CGPoint) -> UIMenu? {
        guard let view else { return nil }
        let c = view.controller
        c.putDown()
        guard let id = c.film(at: p) else { film = nil; return nil }
        film = id
        Self.current = self
        c.select(id)
        // The menu's commands travel the responder chain from the first responder: the table is it, so they reach
        // the window whatever had the keyboard (with none, AppKit shows them greyed).
        if !view.isFirstResponder { view.becomeFirstResponder() }
        let right = UIKeyCommand(title: L("Rotate Right"), image: UIImage(systemName: "rotate.right"),
                                 action: #selector(UIWindow.spkLightTableRotateRight(_:)), input: "r", modifierFlags: [])
        let left = UIKeyCommand(title: L("Rotate Left"), image: UIImage(systemName: "rotate.left"),
                                action: #selector(UIWindow.spkLightTableRotateLeft(_:)), input: "r", modifierFlags: .shift)
        let off = UIKeyCommand(title: L("Take Off"), image: UIImage(systemName: "minus.circle"),
                               action: #selector(UIWindow.spkLightTableTakeOff(_:)), input: UIKeyCommand.inputDelete, modifierFlags: [])
        for k in [right, left, off] { k.wantsPriorityOverSystemBehavior = true }
        return UIMenu(children: [right, left, UIMenu(options: .displayInline, children: [off])])
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = menu(at: location) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    // What the window's actions reach.
    func rotateRight() { if let film { actions.rotateRight(film) } }
    func rotateLeft() { if let film { actions.rotateLeft(film) } }
    func takeOff() { if let film { actions.takeOff(film) } }
}

/// The menu's key commands are sent up the responder chain; the window is on it whatever has the keyboard.
extension UIWindow {
    @objc func spkLightTableRotateRight(_ sender: Any?) { MacLightTableMenu.current?.rotateRight() }
    @objc func spkLightTableRotateLeft(_ sender: Any?) { MacLightTableMenu.current?.rotateLeft() }
    @objc func spkLightTableTakeOff(_ sender: Any?) { MacLightTableMenu.current?.takeOff() }
}
