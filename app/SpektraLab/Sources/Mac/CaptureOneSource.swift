//  CaptureOneSource.swift — Capture One, read one way, as a linked source of the window's library.
//
//  The Mac app's library is the window's . Capture One comes in through
//  the same door as a Finder folder, *Link a Folder*, and becomes a row of Sources:
//
//  - a **catalog** (`<Name>.cocatalog`) is read by the 2.0 library helper (`spklib-host`, the
//    desktop's `LibraryHost`/`LibraryAPI`, copied): `capture_one.probe`, then `capture_one.link`,
//    which mirrors it from a snapshot copy and never writes to the package; its images are listed
//    with the files' paths, wherever on disk they are, and each becomes a frame read in place;
//  - a **session** (a folder holding `<Name>.cosessiondb`) is what the desktop does with one today
//    (`LibraryModel.openCaptureOneSessionFolder`): its folders read as a folder, without Capture
//    One's own cache (`CaptureOne/`) and its trash (`Trash/`).
//
//  Edits stay SpektraLab's, in the library's own store, as for any linked folder. Nothing goes back
//  to Capture One: no rating, no edit, no file (the desktop's rule, `capture_one: {write_back: false}`).

import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// What *Link a Folder* and *Reconnect…* may pick: a folder, and on the Mac a Capture One
    /// catalog too, which is a package where Capture One is installed.
    static var linkable: [UTType] {
        [.folder] + [UTType(filenameExtension: "cocatalog", conformingTo: .package)].compactMap { $0 }
    }
}

enum CaptureOneSource {
    enum Kind: Equatable { case catalog, session }

    /// A catalog package (or a folder holding a `.cocatalogdb`), or a session folder (one holding a
    /// `.cosessiondb`, or that file itself); nil for any other folder.
    static func kind(of url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        if ext == "cocatalog" { return .catalog }
        if ext == "cosessiondb" { return .session }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        if names.contains(where: { $0.lowercased().hasSuffix(".cocatalogdb") }) { return .catalog }
        if names.contains(where: { $0.lowercased().hasSuffix(".cosessiondb") }) { return .session }
        return nil
    }

    /// A session's name is its database's; a catalog's, its package's.
    static func name(of url: URL, _ kind: Kind) -> String {
        if kind == .session {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if let db = names.first(where: { $0.lowercased().hasSuffix(".cosessiondb") }) {
                return (db as NSString).deletingPathExtension
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Folders of a session that are Capture One's own, not pictures: never walked.
    static let sessionSkips: Set<String> = ["CaptureOne", "Trash"]

    /// One helper for the app, started on first use (`LibraryHost`: never at launch).
    static let host = LibraryHost(launch: .init(executable: LibraryHost.bundledExecutable(),
                                                store: LibraryHost.defaultStore))
    static var client: LibraryClient { LibraryClient(host: host) }

    struct Picture: Sendable {
        var file: URL
        /// The Capture One folder it is in, as the frame's path says it: "Nikon Z8 › 2024-01".
        var folder: String
    }

    /// Every image of a catalog that is not in its trash and whose file is there, by the helper's
    /// mirror. Throws the helper's own answer (`LibraryError`): not supported, busy, unavailable.
    static func pictures(ofCatalog url: URL) async throws -> [Picture] {
        let c = client
        let probe = try await c.probeCaptureOne(url)
        guard probe.supported else {
            throw LibraryError(.unsupported, probe.reason ?? "Made by a newer Capture One")
        }
        let link = try await c.linkCaptureOne(url)
        let query = LibraryQuery()       // check_files: true, always
        var out: [Picture] = []
        var offset = 0
        while true {
            let page = try await c.images(link.library, query, offset: offset, limit: 1000)
            for image in page.images where !image.trashed && image.exists != false {
                let file = URL(fileURLWithPath: image.path)
                out.append(Picture(file: file, folder: file.deletingLastPathComponent().lastPathComponent))
            }
            offset += page.images.count
            if page.images.isEmpty || offset >= page.total { break }
        }
        Log.note(.library, "capture one catalog read",
                 ["images": probe.images ?? -1, "listed": out.count, "format": probe.format ?? "?"])
        return out
    }
}
