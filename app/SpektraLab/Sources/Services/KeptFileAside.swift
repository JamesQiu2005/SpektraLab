//  KeptFileAside.swift — a kept file this build cannot read is copied aside, never written over.
//
//  The library (`library.json`), the Light Table (`lighttable.json`), the export recipes and the Mac
//  library's three lists (`MacLibrary/sources.json`, `pairs.json`, `moved.json`) are each one JSON
//  file, read at launch and written whole at the next change. A file that does not decode — a key a
//  later build spells differently, a value it no longer has, a half-written disk — used to read as
//  "nothing kept", and the next change wrote the empty state over it: for `library.json`, every edit
//  of every frame gone, and nothing said. The readers now hand such a file here first. It is copied
//  beside itself as `<name>.unreadable-<seconds since 1970>.<ext>` (the pattern `sources.json` has had
//  since 2026-10-24), the log says which file and why, and the reader carries on as it did. The copy
//  is the person's to bring back; the app never reads it.
//
//  - **Once per content.** The Mac lists are read again at every change, so the same unreadable file
//    passes through here many times; a copy is made only when no copy beside it holds the same bytes.
//  - **Foundation only**, so the macOS checks in `tools/` compile it with the stores that call it.
//    The log is the app's (`Log`, in `Diagnostics.swift`, is UIKit's): `report` is set when the log
//    opens, and stays nil in a check.

import Foundation

enum KeptFileAside {
    /// Where a set-aside is told: the app's log (`Log.open`). Nil in a check.
    nonisolated(unsafe) static var report: ((_ message: String, _ fields: [String: String]) -> Void)?

    /// Copies `url` beside itself as `<name>.unreadable-<seconds>.<ext>`, unless a copy there already
    /// holds the same bytes, and reports it. Returns the copy (the one made, or the one found); nil
    /// when there is no file or it could not be copied. `error` is why it did not read.
    @discardableResult
    static func setAside(_ url: URL, error: Error, now: Date = Date()) -> URL? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: url) else { return nil }
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let prefix = stem + ".unreadable-"
        let found = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .first { (try? Data(contentsOf: $0)) == data }
        if let found { return found }
        let name = prefix + "\(Int(now.timeIntervalSince1970))" + (ext.isEmpty ? "" : "." + ext)
        let aside = folder.appendingPathComponent(name)
        do {
            try fm.copyItem(at: url, to: aside)
        } catch {
            report?("kept file unreadable, and not set aside", ["file": url.lastPathComponent, "error": "\(error)"])
            return nil
        }
        report?("kept file unreadable, set aside", ["file": url.lastPathComponent, "kept": name, "error": "\(error)"])
        return aside
    }
}
