//  LibraryShelf.swift — which file of the library an item is written to (RFC-047 §2, the older-build guard).
//
//  **The double exposure is kept where a build before it does not look.** Every frame of the library is
//  written to `library.json` (`LibraryPersistence`), and a build reads that file whole with a
//  `JSONDecoder`, which passes over a key it does not know. A double exposure written there would reach a
//  build from before 2026-11-07 as a frame with no `double`: a photograph named "Double Exposure 1" whose
//  picture is its guide, developed by that build's queue as if it were a photograph, and exported so.
//  People do go back a build.
//
//  Nothing a build already shipped can be made to skip an item of `library.json`:
//
//  - it has no version gate — `StoredLibrary.schemaVersion` is written (1) and never read;
//  - it has no kind of item it passes over — a frame decodes or the file does not;
//  - and making one item fail to decode would fail the file (`try?` on the whole `StoredLibrary`): that
//    build would open an empty library, and write the empty one over the user's at its next change.
//
//  So a double exposure's item is written to **its own file beside the library**, `doubles.json`, which no
//  build before this one opens. What that does, measured by `tools/double_selftest.swift` against the old
//  build's shape of the file (its `StoredLibrary` without the field):
//
//  - **an older build shows the library without its double exposures** — not a broken photograph;
//  - it **never writes `doubles.json`**, so the double exposures are still there when the testers come
//    back to this build. Two things an older build may have done meanwhile, both mended at launch
//    (`AppModel.holdDoublesToTheLibrary`): removed a photograph a double exposure holds — its layer is
//    empty, as after a removal here — and swept the guide under `Previews` that none of its frames named
//    (`tidyStorage`, files older than an hour) — the guide is drawn again;
//  - the two files are written one after the other in one task, `doubles.json` first: an app ended
//    between the two writes leaves a `doubles.json` one change newer than `library.json`, whose worst case
//    is a layer holding a photograph the library no longer has, which reads as an empty layer
//    (`Darkroom.held(by:)`), and a double exposure about to be added already kept.
//
//  A library written by a development build of 2026-11-07 (the foundation's), which put a double exposure
//  among the frames of `library.json`, still reads: the item is read from there, once, and is moved to its
//  own file at the next write.
//
//  **A `doubles.json` this build cannot read is never written over** (the 2026-11-07 review). Read whole
//  with `try?`, one item this build did not know — a later build's double exposure whose look holds a
//  value it has no case for — made the whole file read as no double exposures, and the next change of
//  the library wrote `frames: []` over it: every double exposure gone, on the return to the newer build
//  too. The failure the paragraph above names for `library.json`, repeated in the new file. So
//  (`read`, `writes`):
//
//  - **each item is read by itself** (`ShelfItem`): one this build cannot read is kept as the JSON it was
//    (`ShelfJSON`) and written back as it was, after the ones it can — the library shows the others;
//  - **a file that does not read at all** — another layout, a file cut short — is copied aside first
//    (`setAside`: `doubles.unreadable-<date>.json`, byte for byte), and `doubles.json` is then not
//    written for the rest of the launch unless a double exposure is made in it: going back to the newer
//    build finds its file as it left it. One made here is kept, and the copy aside still holds the rest.
//
//  **A variant's frame is kept the same way, in `variants.json`** (PRD-G, 2026-11-13). Measured with 2.3.2's own
//  coder (`tools/variant_keep_old.swift`, run by `tools/variant_check.sh` between its runs): a frame of an image's
//  second variant written to `library.json` reaches 2.3.2 as one more frame of the file — its `StoredFrame` has no
//  `variant` key, so it is passed over — and 2.3.2's next save writes every frame back without it. Back in this build
//  each former variant read as a primary, the image's other cells lost their frames, and its first cell joined
//  whichever variant-less frame of the file was indexed last: another variant's edit, shown as the picture's own,
//  silently. In `variants.json` 2.3.2 never sees them, never writes them, and joins the file's row to its primary as
//  it always did. Each item is read by itself, one this build does not read is written back as it was, a file that
//  does not read is set aside (`variants.unreadable-<date>.json`) and not written over, and none is made while the
//  library has no variant's frame (`writes`), as for `doubles.json`. A library written by the variants branch before
//  2026-11-13's evening, with variant frames inside `library.json`, still reads: they are moved at the next write.
//
//  Pure Foundation and generic over the item, so the selftest holds the split and the join on a Mac.

import Foundation

enum LibraryShelf {
    /// The double exposures' own file, beside `library.json`.
    static let doublesFileName = "doubles.json"

    static func doublesURL(beside library: URL) -> URL {
        library.deletingLastPathComponent().appendingPathComponent(doublesFileName)
    }

    /// The variants' frames' own file, beside `library.json` (PRD-G): a frame with a `variant`.
    static let variantsFileName = "variants.json"

    static func variantsURL(beside library: URL) -> URL {
        library.deletingLastPathComponent().appendingPathComponent(variantsFileName)
    }

    /// The library's items, split by file: what an older build may read (photographs and pairs, in the
    /// order they are in) and the double exposures, in theirs.
    static func split<T>(_ items: [T], isDouble: (T) -> Bool) -> (library: [T], doubles: [T]) {
        var library: [T] = [], doubles: [T] = []
        for item in items { if isDouble(item) { doubles.append(item) } else { library.append(item) } }
        return (library, doubles)
    }

    /// The two read back as one library: `library.json`'s items, then the double exposures not already
    /// among them — each id once, the first read kept. (The grid orders by day and import, not by this
    /// list: a double exposure still sits after its bottom photograph, `importedAt`.)
    static func joined<T>(_ library: [T], _ doubles: [T], id: (T) -> UUID) -> [T] {
        var seen = Set(library.map(id))
        var out = library
        for item in doubles where seen.insert(id(item)).inserted { out.append(item) }
        return out
    }

    /// `doubles.json` as read: the items this build reads, the ones it does not — kept as they were, to
    /// be written back — and whether the file was there but did not read at all.
    struct Read<Frame> {
        var frames: [Frame] = []
        var unread: [ShelfJSON] = []
        var unreadable = false
    }

    /// `doubles.json`'s bytes (nil: no file) read item by item (`ShelfItem`).
    static func read<Frame: Codable>(_ data: Data?, as _: Frame.Type, with decoder: JSONDecoder) -> Read<Frame> {
        guard let data else { return Read() }
        guard let shelf = try? decoder.decode(StoredDoubles<ShelfItem<Frame>>.self, from: data) else {
            return Read(unreadable: true)
        }
        var out = Read<Frame>()
        for item in shelf.frames {
            switch item {
            case .read(let frame): out.frames.append(frame)
            case .unread(let json): out.unread.append(json)
            }
        }
        return out
    }

    /// Whether a write of the library writes `doubles.json`: where there is a double exposure to keep —
    /// one this build reads or one it keeps unread — or where the file is there, read, and its double
    /// exposures have all been removed; **never over a file that did not read**, unless one has been made
    /// since (it is then kept, and the copy aside holds what was there).
    static func writes(doubles: Int, unread: Int, fileExists: Bool, unreadable: Bool) -> Bool {
        doubles + unread > 0 || (fileExists && !unreadable)
    }

    /// The copy of a shelf file that did not read, beside it: `doubles.unreadable-<date>.json`,
    /// `variants.unreadable-<date>.json`.
    static func asideURL(of doubles: URL, at date: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stem = doubles.deletingPathExtension().lastPathComponent
        return doubles.deletingLastPathComponent().appendingPathComponent("\(stem).unreadable-\(f.string(from: date)).json")
    }

    /// Copies a `doubles.json` that did not read aside, byte for byte, before anything is written
    /// (`asideURL`); the file itself stays where it is. The copy, or nil where none could be made.
    @discardableResult
    static func setAside(_ doubles: URL, at date: Date = Date(), files: FileManager = .default) -> URL? {
        let aside = asideURL(of: doubles, at: date)
        if files.fileExists(atPath: aside.path) { return aside }
        return (try? files.copyItem(at: doubles, to: aside)) != nil ? aside : nil
    }
}

/// One item of `doubles.json`: one this build reads, or the JSON of one it does not, kept to be written
/// back as it was (`LibraryShelf.read`). Each item is read by itself, so one unknown item fails only itself.
enum ShelfItem<Frame: Codable>: Codable {
    case read(Frame)
    case unread(ShelfJSON)

    init(from decoder: Decoder) throws {
        if let frame = try? Frame(from: decoder) { self = .read(frame) } else { self = .unread(try ShelfJSON(from: decoder)) }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .read(let frame): try frame.encode(to: encoder)
        case .unread(let json): try json.encode(to: encoder)
        }
    }
}

extension ShelfItem: Sendable where Frame: Sendable {}

/// Any JSON, read and written back as it was: an item of `doubles.json` this build does not know. A
/// number is kept as an integer where it is one, so an id or a count is written back as it was read.
indirect enum ShelfJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([ShelfJSON])
    case object([String: ShelfJSON])

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        if let object = try? decoder.container(keyedBy: Key.self) {
            var out: [String: ShelfJSON] = [:]
            for key in object.allKeys { out[key.stringValue] = try object.decode(ShelfJSON.self, forKey: key) }
            self = .object(out)
            return
        }
        if var list = try? decoder.unkeyedContainer() {
            var out: [ShelfJSON] = []
            while !list.isAtEnd { out.append(try list.decode(ShelfJSON.self)) }
            self = .array(out)
            return
        }
        let one = try decoder.singleValueContainer()
        if one.decodeNil() { self = .null }
        else if let b = try? one.decode(Bool.self) { self = .bool(b) }
        else if let i = try? one.decode(Int64.self) { self = .integer(i) }
        else if let d = try? one.decode(Double.self) { self = .number(d) }
        else { self = .string(try one.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let o):
            var c = encoder.container(keyedBy: Key.self)
            for (k, v) in o { try c.encode(v, forKey: Key(stringValue: k)) }
        case .array(let a):
            var c = encoder.unkeyedContainer()
            for v in a { try c.encode(v) }
        case .null: var c = encoder.singleValueContainer(); try c.encodeNil()
        case .bool(let b): var c = encoder.singleValueContainer(); try c.encode(b)
        case .integer(let i): var c = encoder.singleValueContainer(); try c.encode(i)
        case .number(let d): var c = encoder.singleValueContainer(); try c.encode(d)
        case .string(let s): var c = encoder.singleValueContainer(); try c.encode(s)
        }
    }
}

/// `doubles.json` as it is written: a version (1, written for the build after this one to read; none reads
/// it yet, as none reads `StoredLibrary.schemaVersion`) and the double exposures' items in the library's own
/// form (`StoredFrame`). Generic over the item so that the selftest writes and reads one on a Mac.
struct StoredDoubles<Frame: Codable>: Codable {
    var schemaVersion = 1
    var frames: [Frame]

    init(frames: [Frame]) { self.frames = frames }
}
