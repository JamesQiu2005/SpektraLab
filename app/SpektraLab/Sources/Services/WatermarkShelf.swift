//  WatermarkShelf.swift — where a photograph's watermarks are kept in the library: a record of their own beside
//  `library.json`, as the mask layers' is (`LayerShelf`), for the same reason.
//
//  **Measured before choosing, 2026-11-15** (the brief's question: does a plain `FrameEdit` key survive a 2.4.0 build
//  on this app's store?). It does not:
//
//  - **The library's edits are this app's own JSON, not spklib's.** Every edit is a `FrameCatalog` frame's, written
//    to `library.json` by `LibraryPersistence` (MAC-LIBRARY-DATA §3: frames made by `openInDevelop` live there); the
//    helper's catalogs (`spklib-host`, `Library.spkdb`) hold no edit at all (`LayerShelf`'s first point, still true).
//  - **2.4.0 re-encodes every edit through its typed coder** at its next write: `LibraryPersistence.load` decodes
//    `StoredLibrary` (→ `StoredFrame.edit: FrameEdit`), and `write` encodes it back. 2.4.0's `FrameEdit.init(from:)`
//    reads the keys of its `CodingKeys` and its `encode(to:)` writes those only (058f0248, `Model/FrameEdit.swift`:
//    no catch-all, no passthrough of unknown keys). A `watermarks` key in `library.json` would be read past and gone
//    after 2.4.0's first change to the library — the person's marks lost on the return to this build.
//    `tools/watermark_model_selftest.swift` holds this with 2.4.0's coder's own key list (its "the older build" case).
//
//  So **`watermarks.json`, beside `library.json`, one entry a frame by its id** — LayerShelf's rules, each the same:
//
//  - each frame's entry is read by itself (`ShelfItem`): one this build cannot read is kept as the JSON it was and
//    written back as it was; the frame opens without marks;
//  - a file that does not read at all is set aside (`watermarks.unreadable-<date>.json`) and not written over for the
//    rest of the launch unless a mark is placed;
//  - a library whose frames have no mark and no `watermarks.json` makes none: the files on disk of someone who never
//    placed a mark are the files they were;
//  - an entry whose frame is not in the library is dropped at the next write; an unread entry is kept while its frame
//    is there;
//  - written first, before `library.json` (`LibraryPersistence.write`), with the layers' record.
//
//  Read from either place: an edit in `library.json` that does carry `watermarks` (an edit read in whole from elsewhere, a
//  development build's) is read, and the record's entry, where there is one, wins; the next write moves it.
//
//  `FrameEdit.watermarks` keeps its one key and shape everywhere else an edit is written whole (a preset, the
//  clipboard, the edit history): only the library's own file is split.
//
//  Pure Foundation and generic over the frame, so `tools/watermark_model_selftest.swift` holds the split and the join.

import Foundation

enum WatermarkShelf {
    static let fileName = "watermarks.json"

    static func url(beside library: URL) -> URL {
        library.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// The record as written: each frame's marks by its id's string.
    struct Record: Codable {
        enum CodingKeys: String, CodingKey { case version = "version", frames = "frames" }
        var version = 1
        var frames: [String: ShelfItem<[WatermarkPlacement]>] = [:]
    }

    /// `watermarks.json` as read: the marks this build reads, by frame; the ones it does not, kept to be written back;
    /// and whether the file was there but did not read at all.
    struct Read {
        var marks: [UUID: [WatermarkPlacement]] = [:]
        var unread: [UUID: ShelfJSON] = [:]
        var unreadable = false
        var fileExisted = false
    }

    /// `watermarks.json`'s bytes (nil: no file), entry by entry.
    static func read(_ data: Data?) -> Read {
        guard let data else { return Read() }
        guard let record = try? JSONDecoder().decode(Record.self, from: data) else { return Read(unreadable: true, fileExisted: true) }
        var out = Read(fileExisted: true)
        for (key, item) in record.frames {
            guard let id = UUID(uuidString: key) else { continue }
            switch item {
            case .read(let marks): if !marks.isEmpty { out.marks[id] = marks }
            case .unread(let json): out.unread[id] = json
            }
        }
        return out
    }

    /// The frames' edits with the record's marks put in, by id: the record's entry wins over an edit's own.
    static func joined<T>(_ frames: [T], _ read: Read, id: (T) -> UUID, edit: WritableKeyPath<T, FrameEdit>) -> [T] {
        frames.map { frame in
            guard let marks = read.marks[id(frame)] else { return frame }
            var f = frame
            f[keyPath: edit].watermarks = marks
            return f
        }
    }

    /// What is written: the frames with their edits' marks taken out (for `library.json` and its shelves), and the
    /// record (the marks this build holds, then the unread entries of frames still in the library).
    static func split<T>(_ frames: [T], unread: [UUID: ShelfJSON], id: (T) -> UUID,
                         edit: WritableKeyPath<T, FrameEdit>) -> (frames: [T], record: Record, made: Int) {
        var record = Record()
        var out: [T] = []
        out.reserveCapacity(frames.count)
        var present = Set<UUID>()
        for frame in frames {
            present.insert(id(frame))
            let marks = frame[keyPath: edit].watermarks
            guard !marks.isEmpty else { out.append(frame); continue }
            record.frames[id(frame).uuidString] = .read(marks)
            var f = frame
            f[keyPath: edit].watermarks = []
            out.append(f)
        }
        let made = record.frames.count
        for (frameID, json) in unread where present.contains(frameID) && record.frames[frameID.uuidString] == nil {
            record.frames[frameID.uuidString] = .unread(json)
        }
        return (out, record, made)
    }

    /// Whether a write of the library writes `watermarks.json` (`LayerShelf.writes`, the same rule).
    static func writes(entries: Int, made: Int, fileExists: Bool, unreadable: Bool) -> Bool {
        LayerShelf.writes(entries: entries, made: made, fileExists: fileExists, unreadable: unreadable)
    }

    static func encode(_ record: Record) -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(record)
    }

    /// The copy of a `watermarks.json` that did not read, beside it: `watermarks.unreadable-<date>.json`.
    @discardableResult
    static func setAside(_ url: URL, at date: Date = Date(), files: FileManager = .default) -> URL? {
        LibraryShelf.setAside(url, at: date, files: files)
    }
}
