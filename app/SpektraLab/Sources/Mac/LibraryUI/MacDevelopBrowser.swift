//  MacDevelopBrowser.swift — the library, at the develop page's right (the owner, 2026-10-26).
//
//  Since 2026-10-27 the browser is the window's (`MainWindowLayout`), one grid for every mode; what is left
//  here is the develop page's two ways into it: a row opened on the page, and Export's batch.
//
//  "Library and Develop/Edit should also share the same library preview": the develop page stands its
//  canvas beside the same browser the library page has, over the same rows and the same selection
//  (`MacLibraryBrowser`), so what is filtered in the library is what the develop page shows. The
//  filmstrip at the foot of the picture side is the same set seen the other way, and goes in commit 5.
//
//  The bar is the slim one (`MacBrowserHeader.slim`): the count and the search. The library's sidebar,
//  viewer and loupe controls belong to the window's shared bar there, not to a second row here.
//
//  A row clicked is that picture on the page (`open` → the page's `switchFrame`), and a picture the
//  library has never made a frame of is made one first (`CatalogSourcesStore.frames(for:)`), as opening it
//  from the library would. Two of the grid's actions are not offered here, because their dialogs are
//  the library page's: Remove's confirmation and 组成半格组 (`MacLibraryGrid`).

import SwiftUI

/// A picture on the develop page without the mouse: the same thing a click on its row does — its frame,
/// made first if the library has never opened it (`CatalogSourcesStore.frames(for:)`).
@MainActor
enum MacDevelopOpening {
    static func open(_ image: MacImage, store: any MacLibraryData, into open: @escaping (LibraryFrame.ID) -> Void) {
        // The picture this library last opened: a mode press with nothing chosen opens it
        // (`MacLibraryPage.modePicture`).
        MacLibraryBrowser.shared.lastOpened = image.id
        if let id = image.develop?.frameID { open(id); return }
        guard let macStore = store as? CatalogSourcesStore else { return }
        Task {
            guard let made = try? await macStore.frames(for: [image.id]), let id = made.frames[image.id] else { return }
            open(id)
        }
    }
}

/// What the picture bar's Export takes on the Mac (the owner, 2026-10-26: the browser replaces the
/// filmstrip, so the browser is where a batch is chosen): the frames chosen in the browser, in its order;
/// with fewer than two, the open picture alone — one chosen is no batch, as the strip had it.
@MainActor
enum MacDevelopExport {
    static func ids(current: LibraryFrame.ID, model: AppServices) -> [LibraryFrame.ID] {
        ids(current: current, rows: MacLibraryUI.store(model).images, selection: MacLibraryBrowser.shared.selection)
    }

    static func ids(current: LibraryFrame.ID, rows: [MacImage], selection: Set<MacImage.ID>) -> [LibraryFrame.ID] {
        let chosen = rows.filter { selection.contains($0.id) }.compactMap { $0.develop?.frameID }
        return chosen.count < 2 ? [current] : chosen
    }
}
