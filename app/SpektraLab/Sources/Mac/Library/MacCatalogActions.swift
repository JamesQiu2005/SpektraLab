//  MacCatalogActions.swift — the catalog commands every way in shares (2026-10-24): the sidebar's
//  source picker, its "+" menu, the empty library, and Settings › Sources.
//
//  - *New Catalog…*: a save panel (`~/Pictures`, "SpektraLab Catalog"), then an empty `.spkcatalog`.
//  - *Copy to SpektraLab Catalog…* on a Capture One catalog: a save panel ("<catalog>.spkcatalog" in
//    `~/Pictures`), then spklib 0.3.0's `capture_one.copy` with the mirror's SpektraLab ratings and labels;
//    the copy opens, and the Capture One source stays on the list.
//  - *Update from Capture One* on a copy: `capture_one.update`, SpektraLab winning; the counts in the
//    activity line.
//  Each returns what went wrong in words, or nil; the progress is the store's activity line.

import Foundation

@MainActor
enum MacCatalogActions {
    static var pictures: URL { URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Pictures") }

    static func newCatalog(_ store: any MacLibraryData) async -> String? {
        guard let url = await MacSavePanel.catalogPlace(name: MacImportSession.freeName("SpektraLab Catalog", in: pictures),
                                                        in: pictures, message: L("Where the new catalog is kept")) else { return nil }
        do { _ = try await store.newCatalog(at: url); return nil } catch { return words(error) }
    }

    static func copyToCatalog(_ store: any MacLibraryData, _ source: MacSource) async -> String? {
        guard source.kind == .captureOneCatalog else { return nil }
        guard let url = await MacSavePanel.catalogPlace(name: MacImportSession.freeName(source.name, in: pictures), in: pictures,
                                                        message: L("Where the copy of \(source.name) is kept")) else { return nil }
        do { _ = try await store.copyCaptureOne(source.id, to: url); return nil } catch { return words(error) }
    }

    static func update(_ store: any MacLibraryData, _ source: MacSource) async -> String? {
        do { _ = try await store.updateFromCaptureOne(source.id); return nil } catch { return words(error) }
    }

    /// The helper's refusals in the person's words.
    static func words(_ error: Error) -> String {
        switch (error as? LibraryError)?.code {
        case .exists?: L("A catalog is already there. Choose another name or place.")
        case .sourceBusy?: L("Capture One is writing to its catalog. Try again in a moment.")
        case .readOnly?: L("This catalog was not copied from Capture One.")
        case .unknownMethod?: L("This SpektraLab's library helper cannot copy a Capture One catalog yet.")
        default: error.localizedDescription
        }
    }
}
