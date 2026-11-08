//  CopySettingsDialog.swift — C7 Copy Settings. the page layout
//
//  `gen_flow.copy_sheet`: the desktop clipboard's groups (RFC-027), ticked at
//  copy time, each with what it holds for this frame under its name. Pasting
//  is available in Develop/Edit and in Library Select (B4).
//
//  **Seven groups, as drawn.** The seventh is Film Edge & Date Back, unticked
//  when the sheet opens: a film and its date are a frame's own more often
//  than they are a roll's. The rows are `ClipboardGroup.offered`; were those
//  features held back again (`FeatureFlags`) the row would go with them — a
//  box for settings that cannot be seen or changed would be a box that lies.
//
//  The frame's edit is read from the library: the develop page's session
//  writes every change through to it, so this is what the page shows.

import SwiftUI

struct CopySettingsDialog: View {
    let frameID: LibraryFrame.ID

    @Environment(AppServices.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(FrameCatalog.self) private var library
    @State private var picked: Set<ClipboardGroup>

    init(frameID: LibraryFrame.ID) {
        self.frameID = frameID
        // The Mac opens with the ticks last copied with, which ⌘C copies without the sheet
        // (`ClipboardGroup.remembered`); the window and the reference device with the sheet's own.
        _picked = State(initialValue: ClipboardGroup.remembered())
    }

    private func copy() {
        ClipboardGroup.remember(picked)
        model.copySettings(of: frameID, groups: picked)
        router.dismissSheet()
    }

    var body: some View {
        NavigationStack {
            List {
                SettingsGroupPicker(picked: $picked, edit: model.openSession(frameID)?.transferableSettings ?? library.frame(frameID)?.edit ?? .default)
            }
            .navigationTitle(L("Copy Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { router.dismissSheet() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Copy")) { copy() }.disabled(picked.isEmpty)
                }
            }
        }
        .macPageActions(confirmTitle: L("Copy"), confirmEnabled: !picked.isEmpty, confirm: { copy() },
                        cancel: { router.dismissSheet() })
    }

}

/// Where the sheets' bottom button sits: its bottom edge 32 pt above the
/// screen's (the drawings' `capsule_button(16, 772, …, h=48)` on an 852 pt page).
enum SheetLayout {
    static let buttonBottom: CGFloat = 32
}
