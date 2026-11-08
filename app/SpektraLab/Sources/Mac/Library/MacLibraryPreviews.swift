//  MacLibraryPreviews.swift — the Mac library's side of `LibraryPreviews` (2026-11-05): which library a
//  source's previews are kept in, the frames carried from it, the move of a 2.1.3 develop into it, and
//  Settings › Storage's *Delete Previews*.
//
//  The owner: "Preview film renders would be managed by the catalog / session in Capture One style,
//  instead of the current way of keeping them in the internal cache part." A frame's kept develop is
//  Capture One's preview, and it is now kept in the library the picture was opened from
//  (`Services/LibraryPreviews.swift` has the layout and the rules). The helper is not changed: the
//  folder is derived from the library it already names (`MacSource.libraryPath`, `library.info.path`)
//  and its kind. The full-size renders (`.spkfull`) stay the app's, under their own budget: they are a
//  working cache of this Mac's, up to a gigabyte each, and are not what a library keeps.

import Foundation

extension MacSource {
    /// Where this source's frames keep their develops: the helper's library behind it — a catalog's
    /// package, a session's folder, a Capture One catalog's mirror (never the `.cocatalog`), the app's
    /// own catalog for a Capture One session or a Finder folder. Nil for the app library, and for a
    /// Capture One catalog not linked yet.
    var previewHome: PreviewHome? {
        guard kind != .appLibrary else { return nil }
        let own = kind == .catalog || kind == .session ? path : nil
        guard let root = libraryPath ?? own else { return nil }
        return PreviewHome(root: URL(fileURLWithPath: root), kind: kind == .session ? .session : .catalog)
    }
}

/// What a library's previews take, for Settings › Storage: measured off the main thread, sizes only.
struct MacPreviewsUsage: Equatable, Sendable {
    var home: PreviewHome?
    var files = 0
    var bytes: Int64 = 0
    /// The library is there (its disk mounted, the catalog where it was).
    var isThere = false
    /// Its previews folder has been made (the first develop kept there makes it).
    var hasFolder = false

    static func measure(_ home: PreviewHome?) async -> MacPreviewsUsage {
        guard let home else { return MacPreviewsUsage() }
        return await Task.detached(priority: .utility) {
            let counted = LibraryPreviews.measure(home)
            var isDir: ObjCBool = false
            let made = FileManager.default.fileExists(atPath: home.folder.path, isDirectory: &isDir) && isDir.boolValue
            return MacPreviewsUsage(home: home, files: counted.files, bytes: counted.bytes, isThere: home.isThere, hasFolder: made)
        }.value
    }
}

extension AppServices {
    /// The frames were carried from `source` (Develop, Export and the carried filmstrip all pass through
    /// `CatalogSourcesStore.frames(for:)`): their develops are kept in its previews from now on. One kept in
    /// the app's `Previews` (2.1.3 and before, or made while the library's disk was away) moves in now,
    /// under its own name — off the main thread, and the frame is pointed at it only if its develop is
    /// still that file when the move is done; one replaced meanwhile is nobody's and goes.
    ///
    /// And every carried frame's develop is looked for where the frame says it is (review, 2026-11-05;
    /// `LibraryPreviews.locate`), off the main thread and only while the library is there: a catalog moved
    /// or copied in Finder took its previews with it, so a develop found under its own name in this
    /// library's previews is the frame's again (the frame is pointed there); one on a disk that is not
    /// mounted is away and left as it is; one gone from a disk that is here is marked missing
    /// (`DevelopedPicture.markedMissing`), so the develop page, Export and the Light Table develop it again.
    func housePreviews(_ ids: [LibraryFrame.ID], from source: MacSource) {
        guard let home = source.previewHome, !ids.isEmpty else { return }
        LibraryPreviews.house(ids, in: home)
        let app = ImportService.previews.standardizedFileURL.path + "/"
        let carried = ids.compactMap { id -> (LibraryFrame.ID, URL)? in
            guard let d = library.frame(id)?.developed, !d.isMissing, let url = d.picture.fileURL else { return nil }
            return (id, url)
        }
        guard !carried.isEmpty else { return }
        enum Change { case moved(URL), found(URL), missing }
        Task.detached(priority: .utility) { [weak self] in
            guard home.isThere else { return }
            var changes: [(LibraryFrame.ID, URL, Change)] = []
            for (id, was) in carried {
                switch LibraryPreviews.locate(was, carriedFrom: home) {
                case .there:
                    if was.standardizedFileURL.path.hasPrefix(app), let now = LibraryPreviews.move(was, into: home) { changes.append((id, was, .moved(now))) }
                case .at(let now): changes.append((id, was, .found(now)))
                case .away: break
                case .gone: changes.append((id, was, .missing))
                }
            }
            guard !changes.isEmpty else { return }
            await MainActor.run {
                guard let self else { return }
                var moved = 0, found = 0, missing = 0
                for (id, was, change) in changes {
                    let current = self.library.frame(id)?.developed
                    // The frame's develop is still the file looked for: otherwise it was developed again meanwhile.
                    let still = current?.picture.fileURL == was && current?.isMissing == false
                    switch change {
                    case .moved(let now), .found(let now):
                        if still {
                            self.library.update(id) { $0.developed?.picture = .file(now) }
                            if case .moved = change { moved += 1 } else { found += 1 }
                        } else if current?.picture.fileURL != now {
                            try? FileManager.default.removeItem(at: now)      // replaced meanwhile: nobody's
                        }
                    case .missing:
                        guard still else { continue }
                        self.library.update(id) { $0.developed = $0.developed?.markedMissing }
                        missing += 1
                    }
                }
                self.library.measureStorage()
                if found + missing > 0 { self.macLibrary.refreshDevelopInfo() }
                Log.note(.library, "carried frames' previews checked", ["moved": moved, "found": found, "missing": missing])
            }
        }
    }

    /// Settings › Storage's *Delete Previews* for one library: every kept develop in its previews goes but
    /// the one of a frame a develop page has open. The frames whose develop was there keep what was known
    /// of it — its size, so the Light Table still takes the frame (`MacLightTableCarry.takes`) and a film
    /// edge's canvas keeps its shape (`MacShownFrame.aspect`) — and only its picture is missing
    /// (`DevelopedPicture.markedMissing`, review 2026-11-05): the library row reads *not developed*, the
    /// tile shows the camera's preview, and the frame is developed again when it is next opened, exported
    /// or laid on the table, as Capture One makes a deleted preview again. Their edits are untouched. What went.
    @discardableResult
    func deletePreviews(of home: PreviewHome) async -> (files: Int, bytes: Int64) {
        let folder = home.folder.standardizedFileURL.path + "/"
        var spared = Set<LibraryFrame.ID>()
        for f in library.frames {
            guard let url = f.developed?.picture.fileURL, url.standardizedFileURL.path.hasPrefix(folder) else { continue }
            if openSession(f.id) != nil { spared.insert(f.id); continue }
            library.update(f.id) { $0.developed = $0.developed?.markedMissing }
        }
        // The library is written before the files go: one that still named them after the app was ended
        // would read files that are not there.
        library.flush()
        let went = await Task.detached(priority: .userInitiated) { LibraryPreviews.clear(home, sparing: spared) }.value
        macLibrary.refreshDevelopInfo()
        library.measureStorage()
        Log.note(.library, "library previews deleted", ["files": went.files, "bytes": went.bytes, "spared": spared.count])
        return went
    }
}
