//  LibraryAPI.swift — typed requests and replies for the spklib-host JSON protocol.
//  Field names follow API-SPEC-library-helper.md.

import Foundation

// MARK: - request bodies

/// A JSON value for a request's `params`. Ordered, so a request is the same
/// bytes every time, and with `.raw` for an edit that must not be re-encoded.
indirect enum LibraryValue: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([LibraryValue])
    case object([(String, LibraryValue)])
    case raw(Data)

    static func strings(_ s: [String]) -> LibraryValue { .array(s.map { .string($0) }) }

    var json: Data {
        switch self {
        case .null: return Data("null".utf8)
        case .bool(let b): return Data((b ? "true" : "false").utf8)
        case .int(let i): return Data(String(i).utf8)
        case .string(let s): return LibraryJSON.string(s)
        case .raw(let d): return d
        case .array(let a):
            var out = Data("[".utf8)
            for (i, v) in a.enumerated() {
                if i > 0 { out.append(0x2C) }
                out.append(v.json)
            }
            out.append(Data("]".utf8))
            return out
        case .object(let pairs):
            var out = Data("{".utf8)
            for (i, (k, v)) in pairs.enumerated() {
                if i > 0 { out.append(0x2C) }
                out.append(LibraryJSON.string(k))
                out.append(0x3A)
                out.append(v.json)
            }
            out.append(Data("}".utf8))
            return out
        }
    }
}

enum LibraryJSON {
    /// A JSON string literal, escaped by `JSONEncoder` (paths are full of
    /// spaces, and Capture One's names are in the UI language).
    static func string(_ s: String) -> Data {
        (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
    }

    /// A request's params: the pairs whose value is not nil, in order.
    static func params(_ pairs: [(String, LibraryValue?)]) -> Data {
        LibraryValue.object(pairs.compactMap { k, v in v.map { (k, $0) } }).json
    }

    /// The `id` of a reply line, read off its first bytes. The helper writes
    /// compact JSON with `id` first (`{"id":7,…`), so routing a reply does not
    /// parse a page of 10,000 rows twice. Nil for anything else — the ready
    /// event, or a line that would have to be parsed to be understood.
    static func leadingID(_ line: Data) -> Int? {
        let prefix = Array("{\"id\":".utf8)
        guard line.count > prefix.count, line.starts(with: prefix) else { return nil }
        var value = 0
        var digits = 0
        for byte in line.dropFirst(prefix.count) {
            guard byte >= 0x30, byte <= 0x39 else { break }
            value = value * 10 + Int(byte - 0x30)
            digits += 1
            if digits > 15 { return nil }
        }
        return digits > 0 ? value : nil
    }
}

// MARK: - replies

enum LibraryCoding {
    private struct Envelope<T: Decodable>: Decodable {
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey { case result = "result", error = "error" }
        let result: T?
        let error: ErrorBody?
    }

    private struct ErrorBody: Decodable {
        let code: String
        let message: String
        let revision: Int?

        enum CodingKeys: String, CodingKey { case code = "code", message = "message", data = "data" }
        private struct Payload: Decodable {
            let revision: Int?
            /// The keys as they are written: renaming a property must not move its key.
            enum CodingKeys: String, CodingKey { case revision = "revision" }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try c.decode(String.self, forKey: .code)
            message = (try? c.decode(String.self, forKey: .message)) ?? code
            // `data` is null, an object with `revision`, or something else
            // (`io` carries a SQLite string); only `revision` is used.
            revision = (try? c.decodeIfPresent(Payload.self, forKey: .data))??.revision
        }
    }

    /// The `result` of a reply line, or its `error` thrown as `LibraryError`.
    static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: line)
        } catch {
            throw LibraryError(.unavailable, "The library helper's reply could not be read (\(T.self)): \(error)")
        }
        if let e = envelope.error {
            let code = LibraryError.Code(rawValue: e.code) ?? .internalError
            throw LibraryError(code, e.message, revision: e.revision)
        }
        guard let result = envelope.result else {
            throw LibraryError(.unavailable, "The library helper's reply had neither a result nor an error.")
        }
        return result
    }
}

/// A reply whose content is not used (`library.close`, `collection.update`).
struct LibraryAck: Decodable, Sendable {}

/// `images.remove`'s reply (0.3.1).
struct LibraryRemoved: Decodable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case removed = "removed", refused = "refused" }
    struct Refused: Decodable, Sendable {
        let image: String; let code: String
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey { case image = "image", code = "code" }
    }
    let removed: Int
    let refused: [Refused]
}

struct SDKVersion: Decodable, Sendable, Equatable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case version = "version", abi = "abi", schema = "schema" }
    let version: String
    let abi: Int
    let schema: Int
}

enum LibraryKind: String, Codable, Sendable, Equatable {
    case catalog = "catalog", session = "session"
}

struct LibraryInfo: Decodable, Sendable, Equatable {
    struct Origin: Decodable, Sendable, Equatable {
        /// `none` for SpektraLab's own; `capture_one` for a linked catalog.
        let kind: String
        let path: String?
        let documentUUID: String?
        let format: String?
        let syncedAt: String?

        enum CodingKeys: String, CodingKey {
            case kind = "kind", path = "path", format = "format"
            case documentUUID = "document_uuid", syncedAt = "synced_at"
        }

        var isCaptureOne: Bool { kind == "capture_one" }
    }

    struct Counts: Decodable, Sendable, Equatable {
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey { case images = "images", variants = "variants", edits = "edits" }
        let images: Int
        let variants: Int?
        let edits: Int?
    }

    /// 0.3.0: where a catalog made by `capture_one.copy` came from, and when it was last updated from
    /// there; nil for any other library (and from a helper before 0.3.0, which does not send it).
    struct CopiedFrom: Decodable, Sendable, Equatable {
        let kind: String
        let path: String?
        let documentUUID: String?
        let format: String?
        /// What the catalog's database was when last read: the update skips while it is the same.
        let fingerprint: Fingerprint?
        let copiedAt: String?

        struct Fingerprint: Decodable, Sendable, Equatable {
            let size: Int64?
            let mtimeNs: Int64?
            let changeCounter: Int64?
            enum CodingKeys: String, CodingKey {
                case size = "size", mtimeNs = "mtime_ns", changeCounter = "change_counter"
            }
        }
        let updatedAt: String?

        enum CodingKeys: String, CodingKey {
            case kind = "kind", path = "path", format = "format", fingerprint = "fingerprint"
            case documentUUID = "document_uuid", copiedAt = "copied_at", updatedAt = "updated_at"
        }
    }

    let uuid: String
    let kind: LibraryKind
    let name: String
    let path: String
    let origin: Origin
    let counts: Counts
    let copiedFrom: CopiedFrom?

    enum CodingKeys: String, CodingKey {
        case uuid = "uuid", kind = "kind", name = "name", path = "path", origin = "origin", counts = "counts"
        case copiedFrom = "copied_from"
    }
}

struct LibraryHandle: Decodable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case library = "library", info = "info" }
    let library: String
    let info: LibraryInfo
}

struct LibraryLink: Decodable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case library = "library", info = "info", sync = "sync" }
    let library: String
    let info: LibraryInfo
    let sync: LibrarySyncReport?
}

struct LibrarySyncReport: Decodable, Sendable, Equatable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case skipped = "skipped", images = "images", warnings = "warnings" }
    struct Table: Decodable, Sendable, Equatable {
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey {
            case added = "added", updated = "updated", unchanged = "unchanged", removed = "removed"
        }
        let added: Int?
        let updated: Int?
        let unchanged: Int?
        let removed: Int?
    }
    let skipped: Bool?
    let images: Table?
    let warnings: [String]?

    /// Whether Capture One's catalog had anything new for the mirror.
    var changedAnything: Bool {
        guard skipped != true, let t = images else { return false }
        return (t.added ?? 0) + (t.updated ?? 0) + (t.removed ?? 0) > 0
    }
}

struct CaptureOneProbe: Decodable, Sendable, Equatable {
    /// `catalog` or `session`.
    let document: String?
    let documentUUID: String?
    /// `16.8.6.25 Pro Mac`.
    let format: String?
    let counts: [String: Int]?
    let supported: Bool
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case document = "document", format = "format", counts = "counts", supported = "supported", reason = "reason"
        case documentUUID = "document_uuid"
    }

    var images: Int? { counts?["images"] }
    var isSession: Bool { document == "session" }
}

struct LibraryCollection: Decodable, Sendable, Equatable, Identifiable {
    let uuid: String
    let parent: String?
    /// `root`, `all_images`, `recent_imports`, `recent_captures`, `trash`,
    /// `in_library`, `project`, `group`, `album`, `smart_album`, `folder`.
    /// A role is read off this, never off the name: Capture One's names are in
    /// its UI language ("全部图像").
    let kind: String
    let name: String
    let position: Double?
    let origin: String?
    let editable: Bool
    let imageCount: Int?
    let folder: String?
    /// 0.2.0: what to call it (a nameless Capture One folder's own name) and when it was made, UTC
    /// (a Capture One Recent Imports album's import time).
    let title: String?
    let createdAt: String?

    var id: String { uuid }

    enum CodingKeys: String, CodingKey {
        case uuid = "uuid", parent = "parent", kind = "kind", name = "name", position = "position", origin = "origin",
            editable = "editable", folder = "folder", title = "title"
        case imageCount = "image_count", createdAt = "created_at"
    }

    var isCaptureOne: Bool { origin == "capture_one" }
}

struct LibraryVariant: Decodable, Sendable, Equatable, Identifiable {
    let uuid: String
    let position: Int
    let rating: Int?
    let colorTag: Int?
    /// Nil or 0 when SpektraLab has never stored an edit for it. The helper
    /// answers `null`, not `0`, for a variant with none.
    let editRevision: Int?
    let origin: String?

    var id: String { uuid }
    var hasEdit: Bool { (editRevision ?? 0) > 0 }

    enum CodingKeys: String, CodingKey {
        case uuid = "uuid", position = "position", rating = "rating", origin = "origin"
        case colorTag = "color_tag", editRevision = "edit_revision"
    }
}

struct LibraryImage: Decodable, Sendable, Equatable, Identifiable {
    struct Camera: Decodable, Sendable, Equatable {
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey { case make = "make", model = "model", lens = "lens" }
        let make: String?
        let model: String?
        let lens: String?
    }
    struct Exposure: Decodable, Sendable, Equatable {
        let iso: Double?
        let aperture: Double?
        let shutter: Double?
        let focalLength: Double?
        /// 0.2.0: Capture One stores it as text ("+0.7"); a number or a string is read, anything else is nil
        /// rather than a page that does not decode.
        let compensation: Double?

        enum CodingKeys: String, CodingKey {
            case iso = "iso", aperture = "aperture", shutter = "shutter", compensation = "compensation"
            case focalLength = "focal_length"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            iso = try? c.decodeIfPresent(Double.self, forKey: .iso)
            aperture = try? c.decodeIfPresent(Double.self, forKey: .aperture)
            shutter = try? c.decodeIfPresent(Double.self, forKey: .shutter)
            focalLength = try? c.decodeIfPresent(Double.self, forKey: .focalLength)
            if let d = try? c.decodeIfPresent(Double.self, forKey: .compensation) { compensation = d }
            else if let t = try? c.decodeIfPresent(String.self, forKey: .compensation) {
                // "+0.7", or a fraction as the owner's catalog has it: "0/6", "-1/3".
                let parts = t.split(separator: "/").map { Double($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 2, let n = parts[0], let d = parts[1], d != 0 { compensation = n / d } else { compensation = Double(t) }
            }
            else { compensation = nil }
        }
    }

    let uuid: String
    let path: String
    let fileName: String
    /// `raw`, `raster`, `movie`, `other`.
    let kind: String
    let rating: Int
    let colorTag: Int?
    let trashed: Bool
    /// The camera's wall clock, no zone (`2024-01-08T23:39:04`). Shown as it
    /// is: read as UTC it would be wrong by the shooting place's offset.
    let capturedLocal: String?
    let origin: String?
    /// From `check_files`; nil when the list did not ask.
    let exists: Bool?
    let variants: [LibraryVariant]
    // With `full` (or from `image.get`):
    let width: Int?
    let height: Int?
    let fileSize: Int?
    let camera: Camera?
    let exposure: Exposure?
    /// 0.2.0, with `full`: whether the header has been read (a folder sync adds files unread), and when
    /// Capture One imported it / SpektraLab added it (UTC).
    let described: Bool?
    let importedAt: String?
    let addedAt: String?
    /// `removed` for a file a folder sync found gone (listed with `include_removed`).
    let originState: String?

    var id: String { uuid }
    var url: URL { URL(fileURLWithPath: path) }
    var isOffline: Bool { exists == false }
    var isCaptureOne: Bool { origin == "capture_one" }
    var hasEdit: Bool { variants.contains(where: \.hasEdit) }

    enum CodingKeys: String, CodingKey {
        case uuid = "uuid", path = "path", kind = "kind", rating = "rating", trashed = "trashed", origin = "origin",
            exists = "exists", variants = "variants", width = "width", height = "height", camera = "camera",
            exposure = "exposure", described = "described"
        case fileName = "file_name", colorTag = "color_tag", capturedLocal = "captured_local"
        case fileSize = "file_size", importedAt = "imported_at", addedAt = "added_at", originState = "origin_state"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        path = try c.decode(String.self, forKey: .path)
        fileName = try c.decode(String.self, forKey: .fileName)
        kind = try c.decode(String.self, forKey: .kind)
        rating = try c.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        colorTag = try c.decodeIfPresent(Int.self, forKey: .colorTag)
        trashed = try c.decodeIfPresent(Bool.self, forKey: .trashed) ?? false
        capturedLocal = try c.decodeIfPresent(String.self, forKey: .capturedLocal)
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        exists = try c.decodeIfPresent(Bool.self, forKey: .exists)
        // A page lists variants; `image.get`'s detail has its own type.
        variants = try c.decodeIfPresent([LibraryVariant].self, forKey: .variants) ?? []
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        fileSize = try c.decodeIfPresent(Int.self, forKey: .fileSize)
        camera = try c.decodeIfPresent(Camera.self, forKey: .camera)
        exposure = try c.decodeIfPresent(Exposure.self, forKey: .exposure)
        described = try c.decodeIfPresent(Bool.self, forKey: .described)
        importedAt = try c.decodeIfPresent(String.self, forKey: .importedAt)
        addedAt = try c.decodeIfPresent(String.self, forKey: .addedAt)
        originState = try c.decodeIfPresent(String.self, forKey: .originState)
    }
}

struct LibraryImagePage: Decodable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case total = "total", offset = "offset", images = "images" }
    let total: Int
    let offset: Int
    let images: [LibraryImage]
}

/// `image.get`: the image, every variant with both sides' values, and the
/// albums it is in.
struct LibraryImageDetail: Decodable, Sendable, Equatable {
    struct Variant: Decodable, Sendable, Equatable, Identifiable {
        struct Values: Decodable, Sendable, Equatable {
            let rating: Int?
            let colorTag: Int?
            enum CodingKeys: String, CodingKey { case rating = "rating"; case colorTag = "color_tag" }
        }
        let uuid: String
        let position: Int
        let rating: Int?
        let colorTag: Int?
        let local: Values?
        let captureOne: Values?
        let editRevision: Int?
        let editModifiedAt: String?

        var id: String { uuid }

        enum CodingKeys: String, CodingKey {
            case uuid = "uuid", position = "position", rating = "rating", local = "local"
            case colorTag = "color_tag", captureOne = "capture_one"
            case editRevision = "edit_revision", editModifiedAt = "edit_modified_at"
        }
    }
    struct Album: Decodable, Sendable, Equatable {
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey { case uuid = "uuid", name = "name" }
        let uuid: String?
        let name: String?
    }

    let uuid: String
    let path: String
    let fileName: String
    let kind: String
    let capturedLocal: String?
    let exists: Bool?
    let width: Int?
    let height: Int?
    let fileSize: Int?
    let camera: LibraryImage.Camera?
    let exposure: LibraryImage.Exposure?
    let origin: String?
    let variants: [Variant]
    let albums: [Album]?

    enum CodingKeys: String, CodingKey {
        case uuid = "uuid", path = "path", kind = "kind", exists = "exists", width = "width", height = "height",
            camera = "camera", exposure = "exposure", origin = "origin", variants = "variants", albums = "albums"
        case fileName = "file_name", capturedLocal = "captured_local", fileSize = "file_size"
    }
}

struct LibraryLookup: Decodable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case results = "results" }
    struct Result: Decodable, Sendable {
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey { case path = "path", found = "found", match = "match" }
        struct Match: Decodable, Sendable {
            let image: String; let variant: String?
            /// The keys as they are written: renaming a property must not move its key.
            enum CodingKeys: String, CodingKey { case image = "image", variant = "variant" }
        }
        let path: String
        let found: Bool
        let match: Match?
    }
    let results: [Result]
}

struct LibraryLocation: Decodable, Sendable, Equatable, Identifiable {
    let uuid: String
    let path: String?
    let volume: String?
    let relinked: Bool?
    let imageCount: Int?
    let online: Bool

    var id: String { uuid }

    enum CodingKeys: String, CodingKey {
        case uuid = "uuid", path = "path", volume = "volume", relinked = "relinked", online = "online"
        case imageCount = "image_count"
    }
}

struct LibraryEdit: Decodable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case revision = "revision" }
    /// 0 = none.
    let revision: Int
    // `edit` (the desktop's Sidecar) is not read: the Mac app keeps its edits in the window's
    // own library store, and reads a library's pictures only .
}

struct LibraryEditWrite: Decodable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case revision = "revision" }
    let revision: Int
}

struct LibraryNewVariant: Decodable, Sendable {
    let variant: String
    let position: Int
    let editCopied: Bool?

    enum CodingKeys: String, CodingKey {
        case variant = "variant", position = "position"
        case editCopied = "edit_copied"
    }
}

struct LibraryAdd: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let path: String?
        let image: String?
        let variant: String?
        let existing: Bool?
        let storedAt: String?
        /// The helper writes `{code, message}` here (`not_found`, `io`); a bare string is read too. It
        /// was a `String` until 2026-10-24, so one refused file made the whole reply fail to decode.
        let error: String?
        enum CodingKeys: String, CodingKey {
            case path = "path", image = "image", variant = "variant", existing = "existing", error = "error"
            case storedAt = "stored_at"
        }
        private struct Problem: Decodable {
            let code: String?; let message: String?
            /// The keys as they are written: renaming a property must not move its key.
            enum CodingKeys: String, CodingKey { case code = "code", message = "message" }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decodeIfPresent(String.self, forKey: .path)
            image = try c.decodeIfPresent(String.self, forKey: .image)
            variant = try c.decodeIfPresent(String.self, forKey: .variant)
            existing = try c.decodeIfPresent(Bool.self, forKey: .existing)
            storedAt = try c.decodeIfPresent(String.self, forKey: .storedAt)
            if let text = try? c.decodeIfPresent(String.self, forKey: .error) { error = text }
            else if let p = try? c.decodeIfPresent(Problem.self, forKey: .error) { error = p.message ?? p.code ?? "error" }
            else { error = nil }
        }
    }
    let added: Int
    let results: [Item]
    /// 0.2.0: the Recent Imports album this call made (none when nothing was new, or with
    /// `recent_import: false`). The import flow's later chunks go into it (`collection:`).
    let recentImport: String?

    enum CodingKeys: String, CodingKey {
        case added = "added", results = "results"
        case recentImport = "recent_import"
    }
}

struct LibraryNewCollection: Decodable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case collection = "collection" }
    let collection: String?
}

struct SessionFolder: Decodable, Sendable, Equatable, Identifiable {
    let location: String?
    let path: String
    let relativePath: String?
    /// `capture`, `selects`, `output`, `trash`, or nil for a plain folder.
    let role: String?
    let outsideSession: Bool?
    let exists: Bool?
    let imageCount: Int?

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case location = "location", path = "path", role = "role", exists = "exists"
        case relativePath = "relative_path", outsideSession = "outside_session", imageCount = "image_count"
    }
}

struct SessionFolders: Decodable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case root = "root", folders = "folders" }
    let root: String?
    let folders: [SessionFolder]
}

struct SessionScan: Decodable, Sendable, Equatable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case seen = "seen", added = "added", missing = "missing" }
    let seen: Int
    let added: Int
    let missing: Int
}

struct SessionMove: Decodable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case moved = "moved" }
    struct Moved: Decodable, Sendable {
        let image: String; let from: String?; let to: String?
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey { case image = "image", from = "from", to = "to" }
    }
    let moved: [Moved]
}

struct SessionTrashPlan: Decodable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case files = "files" }
    struct File: Decodable, Sendable {
        let image: String; let path: String
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey { case image = "image", path = "path" }
    }
    let files: [File]
}

// MARK: - 0.2.0 replies

/// `images.facets`: counts over a scope, each facet without its own filter keys.
struct LibraryFacets: Decodable, Sendable, Equatable {
    struct Count: Decodable, Sendable, Equatable {
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey { case value = "value", count = "count", make = "make" }
        /// A number (rating, colour tag) or a string (kind, date, camera, lens, keyword), or null
        /// for "not known" (a file with no camera in its header).
        let value: Value
        let count: Int
        /// The camera facet: the maker beside the model.
        let make: String?

        enum Value: Decodable, Sendable, Equatable, Hashable {
            case int(Int), string(String), none
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if c.decodeNil() { self = .none }
                else if let i = try? c.decode(Int.self) { self = .int(i) }
                else { self = .string(try c.decode(String.self)) }
            }
            var int: Int? { if case .int(let i) = self { i } else { nil } }
            var string: String? { if case .string(let s) = self { s } else { nil } }
        }
    }
    struct Captured: Decodable, Sendable, Equatable {
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey {
            case years = "years", months = "months", days = "days", undated = "undated"
        }
        let years: [Count]
        let months: [Count]
        let days: [Count]
        let undated: Int
    }
    struct Edited: Decodable, Sendable, Equatable {
        let yes: Int; let no: Int
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey { case yes = "yes", no = "no" }
    }

    let total: Int
    let rating: [Count]
    let colorTag: [Count]
    let kind: [Count]
    let captured: Captured
    let camera: [Count]
    let lens: [Count]
    let keyword: [Count]
    let edited: Edited
    let undescribed: Int

    enum CodingKeys: String, CodingKey {
        case total = "total", rating = "rating", kind = "kind", captured = "captured", camera = "camera", lens = "lens",
            keyword = "keyword", edited = "edited", undescribed = "undescribed"
        case colorTag = "color_tag"
    }
}

/// One folder's pass of `folders.sync` (or `folders.add`'s first look).
struct LibraryFolderSync: Decodable, Sendable, Equatable {
    let folder: String?
    let path: String?
    let offline: Bool?
    let seen: Int?
    let added: Int?
    let moved: Int?
    let removed: Int?
    let restored: Int?
    let updated: Int?
    let unchanged: Int?
    let ms: Double?
    let recentImport: String?

    enum CodingKeys: String, CodingKey {
        case folder = "folder", path = "path", offline = "offline", seen = "seen", added = "added", moved = "moved",
            removed = "removed", restored = "restored", updated = "updated", unchanged = "unchanged", ms = "ms"
        case recentImport = "recent_import"
    }

    var changedAnything: Bool { (added ?? 0) + (moved ?? 0) + (removed ?? 0) + (restored ?? 0) + (updated ?? 0) > 0 }
}

struct LibraryFoldersSync: Decodable, Sendable, Equatable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case folders = "folders", session = "session", added = "added", moved = "moved", removed = "removed",
            restored = "restored"
    }
    let folders: [LibraryFolderSync]
    let session: LibraryFolderSync?
    let added: Int
    let moved: Int
    let removed: Int
    let restored: Int

    var changedAnything: Bool { added + moved + removed + restored > 0 || folders.contains(where: \.changedAnything) }
}

struct LibraryFolderAdded: Decodable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case folder = "folder", collection = "collection", path = "path", sync = "sync"
    }
    let folder: String
    let collection: String
    let path: String
    let sync: LibraryFolderSync
}

struct LibraryWatchedFolder: Decodable, Sendable, Equatable, Identifiable {
    let folder: String
    let path: String
    let recursive: Bool
    let collection: String?
    let online: Bool
    let imageCount: Int
    let syncedAt: String?

    var id: String { folder }

    enum CodingKeys: String, CodingKey {
        case folder = "folder", path = "path", recursive = "recursive", collection = "collection", online = "online"
        case imageCount = "image_count", syncedAt = "synced_at"
    }
}

/// What the app read of a file's header, for `images.describe` (the `images.add` metadata keys).
struct LibraryDescription: Sendable, Equatable {
    var image: String
    var capturedLocal: String?
    var width: Int?
    var height: Int?
    var cameraMake: String?
    var cameraModel: String?
    var lens: String?
    var iso: Int?
    var aperture: Double?
    var shutter: Double?
    var focalLength: Double?

    var value: LibraryValue {
        func num(_ d: Double?) -> LibraryValue? { d.map { .raw(Data(String($0).utf8)) } }
        let meta: [(String, LibraryValue?)] = [
            ("captured_local", capturedLocal.map { .string($0) }),
            ("width", width.map { .int($0) }), ("height", height.map { .int($0) }),
            ("camera_make", cameraMake.map { .string($0) }), ("camera_model", cameraModel.map { .string($0) }),
            ("lens", lens.map { .string($0) }), ("iso", iso.map { .int($0) }),
            ("aperture", num(aperture)), ("shutter", num(shutter)), ("focal_length", num(focalLength)),
        ]
        return .object([("image", .string(image)), ("metadata", .object(meta.compactMap { k, v in v.map { (k, $0) } }))])
    }
}

// MARK: - 0.3.0 replies: a Capture One catalog copied into a SpektraLab one, and updated from it

/// A count the reply gives as a number, or as an object of numbers (`{added, updated, …}`): read as
/// numbers by name, `total` for a bare number. Anything else is left out rather than failing the reply.
struct LibraryCounts: Decodable, Sendable, Equatable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case values = "values" }
    var values: [String: Int] = [:]

    init(_ values: [String: Int] = [:]) { self.values = values }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { values = ["total": n] }
        else if let o = try? c.decode([String: LibraryLooseNumber].self) { values = o.compactMapValues(\.int) }
    }

    subscript(_ key: String) -> Int { values[key] ?? 0 }
    var sum: Int { values.values.reduce(0, +) }
}

/// A number, or anything else (read as nil).
struct LibraryLooseNumber: Decodable, Sendable, Equatable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case int = "int" }
    let int: Int?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { int = i }
        else if let d = try? c.decode(Double.self) { int = Int(d) }
        else if let a = try? c.decode([LibraryLooseNumber].self) { int = a.count }
        else { int = nil }
    }
}

/// `capture_one.copy`: the new library (origin `none`, every row SpektraLab's own) and what went into it.
struct LibraryCopy: Decodable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case library = "library", info = "info", report = "report" }
    struct Report: Decodable, Sendable, Equatable {
        let images: Int?
        let variants: Int?
        let collections: Int?
        let folders: Int?
        let keywords: Int?
        let albumMembers: Int?
        let warnings: [String]?
        let ms: Double?

        enum CodingKeys: String, CodingKey {
            case images = "images", variants = "variants", collections = "collections", folders = "folders",
                keywords = "keywords", warnings = "warnings", ms = "ms"
            case albumMembers = "album_members"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func n(_ k: CodingKeys) -> Int? { (try? c.decodeIfPresent(LibraryLooseNumber.self, forKey: k))??.int }
            images = n(.images); variants = n(.variants); collections = n(.collections); folders = n(.folders)
            keywords = n(.keywords); albumMembers = n(.albumMembers)
            warnings = try? c.decodeIfPresent([String].self, forKey: .warnings)
            ms = try? c.decodeIfPresent(Double.self, forKey: .ms)
        }
    }
    let library: String
    let info: LibraryInfo
    let report: Report
}

/// `capture_one.update`: what changed in Capture One since the copy (or the last update), taken in.
/// SpektraLab's own changes win where both changed (`conflicts_kept`).
struct LibraryUpdate: Decodable, Sendable, Equatable {
    let images: LibraryCounts?
    let collections: LibraryCounts?
    let folders: LibraryCounts?
    let members: LibraryCounts?
    let conflictsKept: Int?
    let skipped: Bool?
    let warnings: [String]?
    let ms: Double?

    enum CodingKeys: String, CodingKey {
        case images = "images", collections = "collections", folders = "folders", members = "members",
            skipped = "skipped", warnings = "warnings", ms = "ms"
        case conflictsKept = "conflicts_kept"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        images = try? c.decodeIfPresent(LibraryCounts.self, forKey: .images)
        collections = try? c.decodeIfPresent(LibraryCounts.self, forKey: .collections)
        folders = try? c.decodeIfPresent(LibraryCounts.self, forKey: .folders)
        members = try? c.decodeIfPresent(LibraryCounts.self, forKey: .members)
        conflictsKept = (try? c.decodeIfPresent(LibraryLooseNumber.self, forKey: .conflictsKept))??.int
        skipped = try? c.decodeIfPresent(Bool.self, forKey: .skipped)
        warnings = try? c.decodeIfPresent([String].self, forKey: .warnings)
        ms = try? c.decodeIfPresent(Double.self, forKey: .ms)
    }

    /// Whether anything in the library changed: the tree and the rows are read again.
    var changedAnything: Bool {
        guard skipped != true else { return false }
        let i = images ?? LibraryCounts(), parts = [collections, folders, members].compactMap { $0 }
        return i["added"] + i["updated"] + i["gone"] > 0 || parts.contains { $0.sum - $0["unchanged"] > 0 }
    }
}

// MARK: - the client

/// The methods, one Swift call each, over one `LibraryHost`. A `struct` so it
/// can be handed to any task; every call is the actor's.
struct LibraryClient: Sendable {
    let host: LibraryHost

    private func call<T: Decodable>(_ method: String, _ type: T.Type,
                                    _ pairs: [(String, LibraryValue?)] = []) async throws -> T {
        let line = try await host.call(method, LibraryJSON.params(pairs))
        return try LibraryCoding.decode(type, from: line)
    }

    func version() async throws -> SDKVersion { try await call("sdk.version", SDKVersion.self) }

    // MARK: libraries

    func probeCaptureOne(_ path: URL) async throws -> CaptureOneProbe {
        try await call("capture_one.probe", CaptureOneProbe.self, [("path", .string(path.path))])
    }

    func linkCaptureOne(_ source: URL) async throws -> LibraryLink {
        try await call("capture_one.link", LibraryLink.self, [("source", .string(source.path))])
    }

    /// 0.3.0: Capture One's catalog copied into a new SpektraLab catalog at `path`. `mirror`: the linked
    /// mirror's handle, whose SpektraLab ratings, labels and imports go with the copy. Errors: `exists` (a
    /// library is there), `source_busy` (Capture One is writing).
    func copyCaptureOne(_ source: URL, to path: URL, name: String?, mirror: String?) async throws -> LibraryCopy {
        try await call("capture_one.copy", LibraryCopy.self, [
            ("source", .string(source.path)), ("path", .string(path.path)), ("name", name.map { .string($0) }),
            ("mirror", mirror.map { .string($0) }),
        ])
    }

    /// 0.3.0: a copied catalog brought up to date with its Capture One catalog; SpektraLab's own changes
    /// win. `source`: the Capture One catalog's new place, if it moved. Errors: `read_only` (not a copy),
    /// `source_busy`.
    func updateFromCaptureOne(_ library: String, source: URL? = nil, dryRun: Bool = false) async throws -> LibraryUpdate {
        try await call("capture_one.update", LibraryUpdate.self, [
            ("library", .string(library)), ("source", source.map { .string($0.path) }),
            ("dry_run", dryRun ? .bool(true) : nil),
        ])
    }

    func create(at path: URL, kind: LibraryKind, name: String? = nil) async throws -> LibraryHandle {
        try await call("library.create", LibraryHandle.self, [
            ("path", .string(path.path)), ("kind", .string(kind.rawValue)), ("name", name.map { .string($0) }),
        ])
    }

    func open(_ path: URL) async throws -> LibraryHandle {
        try await call("library.open", LibraryHandle.self, [("path", .string(path.path))])
    }

    func close(_ library: String) async throws {
        _ = try await call("library.close", LibraryAck.self, [("library", .string(library))])
    }

    func info(_ library: String) async throws -> LibraryInfo {
        try await call("library.info", LibraryInfo.self, [("library", .string(library))])
    }

    func sync(_ library: String, force: Bool = false, source: URL? = nil) async throws -> LibrarySyncReport {
        try await call("library.sync", LibrarySyncReport.self, [
            ("library", .string(library)), ("force", force ? .bool(true) : nil),
            ("source", source.map { .string($0.path) }),
        ])
    }

    // MARK: browsing

    func collections(_ library: String) async throws -> [LibraryCollection] {
        struct CollectionsReply: Decodable {
            let collections: [LibraryCollection]
            /// The keys as they are written: renaming a property must not move its key.
            enum CodingKeys: String, CodingKey { case collections = "collections" }
        }
        return try await call("collections.list", CollectionsReply.self, [("library", .string(library))]).collections
    }

    func images(_ library: String, _ query: LibraryQuery, offset: Int, limit: Int) async throws -> LibraryImagePage {
        try await call("images.list", LibraryImagePage.self, [("library", .string(library))]
                       + query.pairs + [("offset", .int(offset)), ("limit", .int(limit))])
    }

    func image(_ library: String, _ uuid: String) async throws -> LibraryImageDetail {
        try await call("image.get", LibraryImageDetail.self, [("library", .string(library)), ("image", .string(uuid))])
    }

    func lookup(_ library: String, paths: [URL]) async throws -> LibraryLookup {
        try await call("images.lookup", LibraryLookup.self, [
            ("library", .string(library)), ("paths", .strings(paths.map(\.path))),
        ])
    }

    func locations(_ library: String) async throws -> [LibraryLocation] {
        struct LocationsReply: Decodable {
            let locations: [LibraryLocation]
            /// The keys as they are written: renaming a property must not move its key.
            enum CodingKeys: String, CodingKey { case locations = "locations" }
        }
        return try await call("locations.list", LocationsReply.self, [("library", .string(library))]).locations
    }

    func relink(_ library: String, location: String, to folder: URL?) async throws {
        _ = try await call("location.relink", LibraryAck.self, [
            ("library", .string(library)), ("location", .string(location)),
            ("path", folder.map { .string($0.path) } ?? .null),
        ])
    }

    // MARK: edits

    func edit(_ library: String, variant: String) async throws -> LibraryEdit {
        try await call("edit.get", LibraryEdit.self, [("library", .string(library)), ("variant", .string(variant))])
    }

    /// `edit` is the `Sidecar` as `JSONEncoder` wrote it, spliced in as is.
    func putEdit(_ library: String, variant: String, edit: Data, baseRevision: Int) async throws -> Int {
        try await call("edit.put", LibraryEditWrite.self, [
            ("library", .string(library)), ("variant", .string(variant)),
            ("edit", .raw(edit)), ("base_revision", .int(baseRevision)),
        ]).revision
    }

    func setMeta(_ library: String, variants: [String], rating: Int?? = nil, colorTag: Int?? = nil) async throws {
        func value(_ v: Int??) -> LibraryValue? {
            guard let v else { return nil }
            return v.map { .int($0) } ?? .null
        }
        _ = try await call("meta.set", LibraryAck.self, [
            ("library", .string(library)), ("variants", .strings(variants)),
            ("rating", value(rating)), ("color_tag", value(colorTag)),
        ])
    }

    func newVariant(_ library: String, image: String, from variant: String?) async throws -> LibraryNewVariant {
        try await call("variant.create", LibraryNewVariant.self, [
            ("library", .string(library)), ("image", .string(image)), ("from_variant", variant.map { .string($0) }),
        ])
    }

    /// What `ImageDecoder` would read, passed so the helper never opens a file.
    struct AddItem: Sendable {
        var url: URL
        var capturedLocal: String?
        var width: Int?
        var height: Int?
        var cameraMake: String?
        var cameraModel: String?
        var lens: String?
        // The import flow's (2026-10-24): the exposure the header gave, so the rows say it from the start.
        var iso: Int?
        var aperture: Double?
        var shutter: Double?
        var focalLength: Double?

        var value: LibraryValue {
            func num(_ d: Double?) -> LibraryValue? { d.map { .raw(Data(String($0).utf8)) } }
            let meta: [(String, LibraryValue?)] = [
                ("captured_local", capturedLocal.map { .string($0) }),
                ("width", width.map { .int($0) }), ("height", height.map { .int($0) }),
                ("camera_make", cameraMake.map { .string($0) }), ("camera_model", cameraModel.map { .string($0) }),
                ("lens", lens.map { .string($0) }), ("iso", iso.map { .int($0) }),
                ("aperture", num(aperture)), ("shutter", num(shutter)), ("focal_length", num(focalLength)),
            ]
            let present = meta.compactMap { k, v in v.map { (k, $0) } }
            return present.isEmpty ? .string(url.path)
                : .object([("path", .string(url.path)), ("metadata", .object(present))])
        }
    }

    /// `recentImport` false: no Recent Imports album of its own (an import in chunks makes one with its
    /// first chunk and passes it as `collection` after). `destination`: a copy's folder, relative to the library.
    /// `recentImportAt` (0.3.0, the move of the app library): the Recent Imports album's time, its
    /// `created_at` and its name, instead of now. A helper before 0.3.0 ignores the key, and the move
    /// renames the album itself.
    func add(_ library: String, _ items: [AddItem], copy: Bool, collection: String? = nil,
             recentImport: Bool = true, destination: String? = nil, recentImportAt: Date? = nil) async throws -> LibraryAdd {
        try await call("images.add", LibraryAdd.self, [
            ("library", .string(library)), ("items", .array(items.map(\.value))),
            ("mode", .string(copy ? "copy" : "reference")), ("collection", collection.map { .string($0) }),
            ("recent_import", recentImport ? nil : .bool(false)), ("destination", destination.map { .string($0) }),
            ("recent_import_at", recentImportAt.map { .string(LibraryClient.utc($0)) }),
        ])
    }

    /// A UTC time as the helper writes them (`2026-10-24T07:27:00Z`).
    static func utc(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    /// A SpektraLab collection renamed (`collection.update`).
    func renameCollection(_ library: String, _ collection: String, to name: String) async throws {
        _ = try await call("collection.update", LibraryAck.self, [
            ("library", .string(library)), ("collection", .string(collection)), ("name", .string(name)),
        ])
    }

    func newAlbum(_ library: String, name: String, parent: String? = nil) async throws -> LibraryNewCollection {
        try await call("collection.create", LibraryNewCollection.self, [
            ("library", .string(library)), ("kind", .string("album")), ("name", .string(name)),
            ("parent", parent.map { .string($0) }),
        ])
    }

    func addToAlbum(_ library: String, album: String, images: [String]) async throws {
        _ = try await call("collection.add", LibraryAck.self, [
            ("library", .string(library)), ("collection", .string(album)), ("images", .strings(images)),
        ])
    }

    // MARK: 0.2.0

    func facets(_ library: String, _ query: LibraryQuery) async throws -> LibraryFacets {
        try await call("images.facets", LibraryFacets.self, [("library", .string(library))] + query.scopePairs)
    }

    func describe(_ library: String, _ items: [LibraryDescription]) async throws -> Int {
        struct DescribeReply: Decodable {
            let updated: Int
            /// The keys as they are written: renaming a property must not move its key.
            enum CodingKeys: String, CodingKey { case updated = "updated" }
        }
        return try await call("images.describe", DescribeReply.self, [
            ("library", .string(library)), ("items", .array(items.map(\.value))),
        ]).updated
    }

    /// A referenced folder, watched: its pictures are added where they are, and every
    /// `syncFolders` notices what appeared, went or moved. `skip`: folder names never walked.
    func addFolder(_ library: String, _ folder: URL, recursive: Bool = true, skip: [String] = []) async throws -> LibraryFolderAdded {
        try await call("folders.add", LibraryFolderAdded.self, [
            ("library", .string(library)), ("path", .string(folder.path)), ("recursive", .bool(recursive)),
            ("skip", skip.isEmpty ? nil : .strings(skip)),
        ])
    }

    func watchedFolders(_ library: String) async throws -> [LibraryWatchedFolder] {
        struct FoldersReply: Decodable {
            let folders: [LibraryWatchedFolder]
            /// The keys as they are written: renaming a property must not move its key.
            enum CodingKeys: String, CodingKey { case folders = "folders" }
        }
        return try await call("folders.list", FoldersReply.self, [("library", .string(library))]).folders
    }

    func syncFolders(_ library: String, folder: String? = nil) async throws -> LibraryFoldersSync {
        try await call("folders.sync", LibraryFoldersSync.self, [
            ("library", .string(library)), ("folder", folder.map { .string($0) }),
        ])
    }

    func removeFolder(_ library: String, folder: String) async throws {
        _ = try await call("folders.remove", LibraryAck.self, [("library", .string(library)), ("folder", .string(folder))])
    }

    /// Forget rows whose file is gone (spklib 0.3.1): a half-frame pair's, once its file is deleted. The
    /// helper refuses a row whose file is still there, and never touches a file.
    func removeImages(_ library: String, images: [String]) async throws -> LibraryRemoved {
        try await call("images.remove", LibraryRemoved.self, [("library", .string(library)), ("images", .strings(images))])
    }

    func trash(_ library: String, images: [String], trashed: Bool?) async throws {
        _ = try await call("images.trash", LibraryAck.self, [
            ("library", .string(library)), ("images", .strings(images)), ("trashed", trashed.map { .bool($0) } ?? .null),
        ])
    }

    // MARK: sessions

    func sessionFolders(_ library: String) async throws -> SessionFolders {
        try await call("session.folders", SessionFolders.self, [("library", .string(library))])
    }

    func sessionScan(_ library: String) async throws -> SessionScan {
        try await call("session.scan", SessionScan.self, [("library", .string(library))])
    }

    /// `to` is `capture`, `selects`, `output`, `trash` or a relative folder.
    func sessionMove(_ library: String, images: [String], to role: String) async throws -> SessionMove {
        try await call("session.move", SessionMove.self, [
            ("library", .string(library)), ("images", .strings(images)), ("to", .string(role)),
            ("on_conflict", .string("suffix")),
        ])
    }

    func sessionRestore(_ library: String, images: [String]) async throws -> SessionMove {
        try await call("session.restore", SessionMove.self, [
            ("library", .string(library)), ("images", .strings(images)), ("on_conflict", .string("suffix")),
        ])
    }

    func sessionTrashPlan(_ library: String) async throws -> SessionTrashPlan {
        try await call("session.trash.plan", SessionTrashPlan.self, [("library", .string(library))])
    }

    func sessionTrashCommit(_ library: String, removed: [String]) async throws {
        _ = try await call("session.trash.commit", LibraryAck.self, [
            ("library", .string(library)), ("removed_paths", .strings(removed)),
        ])
    }
}

/// What `images.list` is asked for: the browser's scope, filter and sort.
struct LibraryQuery: Sendable, Equatable {
    enum Sort: String, Sendable, CaseIterable {
        case captured = "captured", imported = "imported", name = "name", rating = "rating", added = "added"
    }

    var collection: String?
    var recursive = true
    var minRating: Int?
    var colorTags: [Int] = []
    var text = ""
    /// SpektraLab's own filter: developed (has an edit) or not.
    var hasEdit: Bool?
    var sort: Sort = .captured
    var descending = false
    // 0.2.0: the facets' filters (any of each), and the page's shape.
    var ratings: [Int] = []
    var kinds: [String] = []
    /// `nil` in the list is "not known".
    var cameraModels: [String?] = []
    var lenses: [String?] = []
    var keywords: [String] = []
    /// `YYYY-MM-DD[THH:MM:SS]`, the camera's wall clock; `to` is exclusive.
    var capturedFrom: String?
    var capturedTo: String?
    var described: Bool?
    /// Only these images (uuids): the Mac's "Developed" filter, which is the app's own knowledge.
    var images: [String]?
    var full = false
    var checkFiles = true
    var includeTrashed = false

    var isFiltered: Bool {
        minRating != nil || !colorTags.isEmpty || !text.isEmpty || hasEdit != nil || !ratings.isEmpty || !kinds.isEmpty
            || !cameraModels.isEmpty || !lenses.isEmpty || !keywords.isEmpty || capturedFrom != nil || capturedTo != nil
            || images != nil
    }

    private var filter: [(String, LibraryValue)] {
        func maybe(_ s: String?) -> LibraryValue { s.map { .string($0) } ?? .null }
        var filter: [(String, LibraryValue)] = []
        if let minRating { filter.append(("min_rating", .int(minRating))) }
        if !ratings.isEmpty { filter.append(("ratings", .array(ratings.map { .int($0) }))) }
        if !colorTags.isEmpty { filter.append(("color_tags", .array(colorTags.map { .int($0) }))) }
        if !kinds.isEmpty { filter.append(("kinds", .strings(kinds))) }
        if !text.isEmpty { filter.append(("text", .string(text))) }
        if let hasEdit { filter.append(("has_edit", .bool(hasEdit))) }
        if !cameraModels.isEmpty { filter.append(("camera_models", .array(cameraModels.map(maybe)))) }
        if !lenses.isEmpty { filter.append(("lenses", .array(lenses.map(maybe)))) }
        if !keywords.isEmpty { filter.append(("keywords", .strings(keywords))) }
        if let capturedFrom { filter.append(("captured_from", .string(capturedFrom))) }
        if let capturedTo { filter.append(("captured_to", .string(capturedTo))) }
        if let described { filter.append(("described", .bool(described))) }
        return filter
    }

    /// The scope alone, which `images.facets` takes.
    var scopePairs: [(String, LibraryValue?)] {
        let filter = self.filter
        return [
            ("collection", collection.map { .string($0) }),
            ("recursive", collection == nil ? nil : .bool(recursive)),
            ("filter", filter.isEmpty ? nil : .object(filter)),
            ("images", images.map { .strings($0) }),
            ("include_trashed", includeTrashed ? .bool(true) : nil),
        ]
    }

    var pairs: [(String, LibraryValue?)] {
        scopePairs + [
            ("sort", .string(sort.rawValue)),
            ("descending", descending ? .bool(true) : nil),
            ("check_files", checkFiles ? .bool(true) : nil),
            ("full", full ? .bool(true) : nil),
        ]
    }
}
