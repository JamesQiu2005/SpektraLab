//  MacSavePanel.swift — AppKit's save panel for a new `.spkcatalog` (2026-10-24).
//
//  The owner: the person decides where a catalog lives, "we do not limit where this .spkcatalog is
//  stored". UIKit's way to a save panel is `UIDocumentPickerViewController(forExporting:)`, which writes
//  a file it is handed, and whose *Replace* would put that file over an existing catalog. A catalog is
//  made by the helper instead, which refuses a place that holds a library (`exists`), so only the
//  panel's answer is wanted: AppKit's `NSSavePanel`, reached through the runtime as `MacScrollMonitor`
//  reaches `NSEvent` and the store `NSWorkspace`. Its *Replace* deletes nothing: nothing is written
//  until the helper makes the catalog, and the helper refuses a place a library is in.

import Foundation
import ObjectiveC

@MainActor
enum MacSavePanel {
    enum Answer: Equatable {
        case chosen(URL)
        case cancelled
        /// No AppKit save panel in this process: the caller keeps its default.
        case unavailable
    }

    /// The save panel, its name field `name`, in `folder`, for a catalog package.
    static func chooseCatalog(name: String, in folder: URL, message: String) async -> Answer {
        guard let cls = NSClassFromString("NSSavePanel") as? NSObject.Type,
              let made = cls.perform(NSSelectorFromString("savePanel"))?.takeUnretainedValue() as? NSObject else {
            Log.warn(.library, "mac save panel: no NSSavePanel")
            return .unavailable
        }
        let panel = made
        panel.setValue(name, forKey: "nameFieldStringValue")
        panel.setValue(folder, forKey: "directoryURL")
        panel.setValue(true, forKey: "canCreateDirectories")
        panel.setValue(false, forKey: "treatsFilePackagesAsDirectories")
        panel.setValue(["spkcatalog"], forKey: "allowedFileTypes")
        panel.setValue(true, forKey: "extensionHidden")
        panel.setValue(message, forKey: "message")
        panel.setValue(L("Create"), forKey: "prompt")
        let begin = NSSelectorFromString("beginWithCompletionHandler:")
        guard panel.responds(to: begin) else { return .unavailable }
        typealias Handler = @convention(block) (Int) -> Void
        typealias Begin = @convention(c) (NSObject, Selector, @escaping Handler) -> Void
        let call = unsafeBitCast(panel.method(for: begin), to: Begin.self)
        #if DEBUG
        shown = panel
        defer { shown = nil }
        #endif
        return await withCheckedContinuation { (done: CheckedContinuation<Answer, Never>) in
            call(panel, begin) { response in
                // NSModalResponseOK is 1.
                if response == 1, let url = panel.value(forKey: "URL") as? URL {
                    done.resume(returning: .chosen(CatalogSourcesStore.catalogURL(url)))
                } else {
                    done.resume(returning: .cancelled)
                }
            }
        }
    }

    #if DEBUG
    /// A check's answer instead of the panel (`--catalog-check`): the panel itself is AppKit's.
    static var debugAnswer: URL?
    /// The panel on screen, for the driver's `panel.cancel` (a scratch copy is not the front app, so a key
    /// posted to it never reaches its panel).
    static var shown: NSObject?
    /// An action of the panel's (`cancel`). Its *Create* cannot be pressed this way: the panel's view is
    /// served from outside the process, `ok:` is "not implemented" and there is no default button cell.
    static func press(_ action: String) {
        guard let shown else { return }
        let sel = NSSelectorFromString(action + ":")
        if shown.responds(to: sel) { shown.perform(sel, with: nil) }
        else { Log.warn(.library, "mac save panel: no such action", ["action": action]) }
    }
    #endif

    /// The panel, or the default itself where there is none (and a check's answer in a debug build).
    static func catalogPlace(name: String, in folder: URL, message: String) async -> URL? {
        #if DEBUG
        if let a = debugAnswer { return a }
        #endif
        switch await chooseCatalog(name: name, in: folder, message: message) {
        case .chosen(let url): return url
        case .cancelled: return nil
        case .unavailable: return folder.appending(path: MacImportSession.freeName(name, in: folder) + ".spkcatalog")
        }
    }
}
