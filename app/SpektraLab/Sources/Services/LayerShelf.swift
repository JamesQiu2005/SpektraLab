//  LayerShelf.swift — where a photograph's mask layers are kept: a record of their own beside the library
//  (PRD-E §5.4, RFC-052 §8.1, the older-build guard).
//
//  **The choice: `layers.json`, beside `library.json` (and `doubles.json`), one entry a frame by its id.** Why there,
//  against `MAC-LIBRARY-DATA.md` and `LibraryPersistence` as they are on 2026-11-13:
//
//  - **Every edit on the Mac is a `FrameCatalog` frame's.** A picture of any source (a catalog, a session, a linked
//    folder, Capture One's) is opened in Develop as a frame of the app library (`openInDevelop`, MAC-LIBRARY-DATA
//    §3: "Frames made by `openInDevelop` live here"), and its `FrameEdit` is that frame's, in `library.json`. The
//    helper's catalogs keep no edit. So a record beside `library.json`, keyed by `LibraryFrame.ID`, reaches every
//    edit there is, and is written in the same task as the library (one writer, one second after the last change,
//    d189e773's rule) — never a second writer racing the first.
//  - **A sibling row of a catalog would not**: the helper's `Library.spkdb` is spklib's, with a schema the app does
//    not own, and a frame's edit is not in it.
//  - **A sibling file per photograph** (`Masks/<photograph>/layers.json`) would be read and written one file a frame,
//    outside the library's one atomic write, and is where RFC-052 §8.2 puts the found masks' *pictures* — which are
//    immutable files, not a record that changes a second after every stroke.
//  - **The precedent is the double exposure's** (`LibraryShelf`, 2026-11-11): `doubles.json` beside the library,
//    which no build before it opens. The same reasons hold here, and the same failures are guarded the same way.
//
//  What a 2.3.x build does with it, measured by `tools/layers_keep_check.swift` with 2.3.1's own `FrameEdit` coder
//  (`git show spektralab-v2.3.1:…`, compiled apart): it reads `library.json`, where the edit carries no `layers` key
//  (it is never written there), shows the picture without its layers, writes `library.json` back after a change of
//  its own — and never opens `layers.json`, so the layers are there when this build reads the library again. Had the
//  layers been written inside the edit, the same round trip drops them (the check's red case).
//
//  The rules, each the doubles' (`LibraryShelf`):
//
//  - **each frame's entry is read by itself** (`ShelfItem`): one this build cannot read — a later build's — is kept as
//    the JSON it was and written back as it was; the frame opens without layers;
//  - **a file that does not read at all is set aside** (`layers.unreadable-<date>.json`) and not written over for the
//    rest of the launch unless a layer is made;
//  - **a library whose frames have no layers and no `layers.json` makes none**: the library on disk of someone who
//    never made a layer is the files it was;
//  - an entry whose frame is not in the library is dropped at the next write (the frame was removed, here or by an
//    older build); an unread entry is kept while its frame is there.
//  - **written first**, before `library.json` (`LibraryPersistence.write`): an app ended between the two leaves a
//    `layers.json` one change newer than the library, whose worst case is a frame's layers a step ahead of its edit.
//
//  Read from either place: an edit in `library.json` that does carry `layers` (a development build's) is read, and
//  the record's entry, where there is one, wins; the next write moves it.
//
//  Pure Foundation and generic over the frame, so `tools/layers_keep_check.swift` holds the split and the join on a Mac.

import Foundation

enum LayerShelf {
    static let fileName = "layers.json"

    static func url(beside library: URL) -> URL {
        library.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// The record as written: each frame's layers by its id's string.
    struct Record: Codable {
        enum CodingKeys: String, CodingKey { case version = "version", frames = "frames" }
        var version = 1
        var frames: [String: ShelfItem<LocalLayers>] = [:]
    }

    /// `layers.json` as read: the layers this build reads, by frame; the ones it does not, kept to be written back;
    /// and whether the file was there but did not read at all.
    struct Read {
        var layers: [UUID: LocalLayers] = [:]
        var unread: [UUID: ShelfJSON] = [:]
        var unreadable = false
        var fileExisted = false
    }

    /// `layers.json`'s bytes (nil: no file), entry by entry.
    static func read(_ data: Data?) -> Read {
        guard let data else { return Read() }
        guard let record = try? JSONDecoder().decode(Record.self, from: data) else { return Read(unreadable: true, fileExisted: true) }
        var out = Read(fileExisted: true)
        for (key, item) in record.frames {
            guard let id = UUID(uuidString: key) else { continue }
            switch item {
            case .read(let layers): if let kept = layers.kept { out.layers[id] = kept }
            case .unread(let json): out.unread[id] = json
            }
        }
        return out
    }

    /// The frames' edits with the record's layers put in, by id: the record's entry wins over an edit's own.
    static func joined<T>(_ frames: [T], _ read: Read, id: (T) -> UUID, edit: WritableKeyPath<T, FrameEdit>) -> [T] {
        frames.map { frame in
            guard let layers = read.layers[id(frame)] else { return frame }
            var f = frame
            f[keyPath: edit].layers = layers
            return f
        }
    }

    /// What is written: the frames with their edits' layers taken out (for `library.json` and `doubles.json`), and
    /// the record (the layers this build holds, then the unread entries of frames still in the library).
    static func split<T>(_ frames: [T], unread: [UUID: ShelfJSON], id: (T) -> UUID,
                         edit: WritableKeyPath<T, FrameEdit>) -> (frames: [T], record: Record, made: Int) {
        var record = Record()
        var out: [T] = []
        out.reserveCapacity(frames.count)
        var present = Set<UUID>()
        for frame in frames {
            present.insert(id(frame))
            guard let layers = frame[keyPath: edit].layers?.kept else { out.append(frame); continue }
            record.frames[id(frame).uuidString] = .read(layers)
            var f = frame
            f[keyPath: edit].layers = nil
            out.append(f)
        }
        let made = record.frames.count
        for (frameID, json) in unread where present.contains(frameID) && record.frames[frameID.uuidString] == nil {
            record.frames[frameID.uuidString] = .unread(json)
        }
        return (out, record, made)
    }

    /// Whether a write of the library writes `layers.json`: there is an entry to keep, or the file is there, read,
    /// and its layers have all gone; never over a file that did not read, unless a layer has been made since (the
    /// copy aside then holds what was there) — `LibraryShelf.writes`, the same rule.
    static func writes(entries: Int, made: Int, fileExists: Bool, unreadable: Bool) -> Bool {
        if unreadable { return made > 0 }
        return entries > 0 || fileExists
    }

    static func encode(_ record: Record) -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(record)
    }

    /// The copy of a `layers.json` that did not read, beside it: `layers.unreadable-<date>.json`, byte for byte.
    @discardableResult
    static func setAside(_ url: URL, at date: Date = Date(), files: FileManager = .default) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let aside = url.deletingLastPathComponent().appendingPathComponent("layers.unreadable-\(f.string(from: date)).json")
        if files.fileExists(atPath: aside.path) { return aside }
        return (try? files.copyItem(at: url, to: aside)) != nil ? aside : nil
    }
}
