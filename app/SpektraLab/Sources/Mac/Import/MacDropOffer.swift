//  MacDropOffer.swift — which drags 松手即导入 (Drop to Import) answers, and when its note goes (2026-11-09).
//
//  The owner, 2026-11-09 (PRD-C): the note "appears for **any** image dragged over the window", and "when
//  the drag leaves without dropping, or ends anywhere else, the app does not notice: the import overlay
//  stays up". Both were SwiftUI's `onDrop`: it asked only whether some item *conformed* to a picture (a
//  picture dragged off a web page, as data, does), could not tell a drag that began in this app from one
//  that came from Finder, and on Catalyst does not always say a drag has left (`dropExited`) — a drag
//  cancelled with Esc, dropped on another app or ended outside the window left `dropping` true for good.
//  Now the window and the import page take drops through UIKit's `UIDropInteraction`
//  (`MacImportDropZone`), whose session says where it began and always ends (`sessionDidEnd`), and what a
//  drag offers is decided here, before anything is read:
//
//  | the drag | | why |
//  |---|---|---|
//  | began in this app (a thumbnail, the filmstrip) | refused | the picture is in the library already; the import page is for files from outside |
//  | a file from Finder: a picture, a RAW, a folder, a catalog or session | taken | what the import page takes; Finder's item is the file's type + `com.apple.finder.node`, with no file URL on Catalyst |
//  | a file URL that names no type of its own | taken | the scan decides at the drop (`MacImportDrop.usable`); Finder names a type for almost every file |
//  | a file from Finder that says it is something else: a PDF, text, a LUT | refused | nothing to import (the cursor's ⊘) |
//  | another app's promise of a file (Photos), of a picture | taken | it becomes a file at the drop (`MacImportDrop.read`'s copy) |
//  | a picture off a web page, text from Safari: data, no file and no promise of one | refused | there is no file to import, only pixels or words |
//  | several items | taken if any one is | the drop keeps what it can use and says what it could not |
//
//  And the note (`MacDropNoteState`) is up only while a drag the window takes is over it and the window
//  takes drops now; it goes when the drag leaves, ends anywhere (dropped elsewhere, cancelled, rejected),
//  is dropped, or — a backstop for whatever is not heard — at the next click, key or loss of focus. A
//  stray update after that does not bring it back: only a new drag's entry does.
//
//  Foundation and UniformTypeIdentifiers only: tools/drop_selftest.swift holds it to the table above.

import Foundation
import UniformTypeIdentifiers

/// What a drag offers the import page, before anything of it is read.
enum MacDropVerdict: String, Equatable, Sendable {
    /// Files, or promises of files, of a kind the import page takes.
    case files
    /// It began in this app.
    case inApp
    /// Data with no file behind it: a web page's picture, text.
    case noFile
    /// Files, each of which says it is something the page does not take.
    case notImportable
    /// Nothing at all.
    case empty

    var takes: Bool { self == .files }
}

enum MacDropOffer {
    /// A drag's verdict from its items' type identifiers (`NSItemProvider.registeredTypeIdentifiers`, one
    /// array an item) and whether it began in this app (`UIDropSession.localDragSession`).
    static func verdict(local: Bool, items: [[String]]) -> MacDropVerdict {
        if local { return .inApp }
        guard !items.isEmpty else { return .empty }
        var sawFile = false
        for ids in items {
            guard isFile(ids) else { continue }
            sawFile = true
            if importable(ids) { return .files }
        }
        return sawFile ? .notImportable : .noFile
    }

    /// Finder's own mark on an item it drags. **On Catalyst a Finder drag carries no `public.file-url`**: its
    /// items register the file's own type and this (a Nikon RAW: `com.nikon.raw-image`, `com.apple.finder.node`,
    /// read off the app's log on 2026-11-10). 2.3.0 asked for the file URL alone and took every real Finder
    /// drag for "no file", so Drop to Import was gone. A web page's picture or Safari's text never carries it.
    static let finderNode = "com.apple.finder.node"

    /// The item is a file: Finder's (its node, or a file URL), or another app's promise to make one
    /// (`NSFilePromiseProvider` on the Mac).
    static func isFile(_ ids: [String]) -> Bool {
        ids.contains { $0 == UTType.fileURL.identifier || $0 == finderNode || isPromise($0) }
    }

    /// The pasteboard's names for a file promise as an item provider carries them.
    static func isPromise(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.hasPrefix("com.apple.nsfilepromise") || lower.hasPrefix("com.apple.pasteboard.promised-file")
    }

    /// The types an item names of itself, beyond "a file", "data", "a URL", the path as UTF-8 text (which a
    /// file drag may carry beside its URL) and a promise's own words. None named: what it is decides at the
    /// drop. `public.plain-text` is a text file's own type, and is named.
    static func namedTypes(_ ids: [String]) -> [UTType] {
        let generic: [UTType] = [.fileURL, .url, .data, .item, .content, .utf8PlainText]
        // Finder's node mark says "a file", not what kind (as a type it is dynamic, which would pass any file).
        return ids.filter { !isPromise($0) && $0 != finderNode }.compactMap { UTType($0) }.filter { t in !generic.contains(t) }
    }

    /// A file item the import page takes: a picture (a RAW among them), a folder, a package, a catalog
    /// or session (types the system does not know: dynamic), or one that names no type of its own.
    static func importable(_ ids: [String]) -> Bool {
        let named = namedTypes(ids)
        if named.isEmpty { return true }
        return named.contains { t in
            t.isDynamic || t.conforms(to: .image) || t.conforms(to: .folder) || t.conforms(to: .directory) || t.conforms(to: .package)
                || ["spkcatalog", "spksession", "cocatalog", "cosessiondb"].contains(t.preferredFilenameExtension ?? "")
        }
    }
}

/// Whether the 松手即导入 note is up: the window's, or the import page's.
struct MacDropNoteState: Equatable, Sendable {
    /// A drag is over the target (entered, not yet left, ended or dropped).
    private(set) var over = false
    /// What it offers is taken, and the target takes drops now.
    private(set) var taken = false

    var shown: Bool { over && taken }

    /// A drag came over the target. `accepting`: the target takes drops now (`MacImportDrop.accepts`).
    mutating func entered(_ v: MacDropVerdict, accepting: Bool = true) {
        over = true
        taken = v.takes && accepting
    }

    /// It moved over the target: whether the target takes it may have changed (a sheet came up meanwhile).
    /// Heard only while it is over: an update after it has gone brings nothing back.
    mutating func updated(_ v: MacDropVerdict, accepting: Bool = true) {
        guard over else { return }
        taken = v.takes && accepting
    }

    /// It left the target.
    mutating func exited() { over = false; taken = false }
    /// It ended, wherever: dropped elsewhere, cancelled, refused.
    mutating func ended() { over = false; taken = false }
    /// It was dropped here.
    mutating func dropped() { over = false; taken = false }
    /// A click, a key, the app no longer in front: whatever drag was thought to be over is not.
    mutating func interrupted() { over = false; taken = false }
}
