//  LibraryAPI.swift — the helper's methods, typed (`API-SPEC-library-helper.md`
//  §4; the SDK's own `API-SPEC.md` is authoritative where they differ).
//
//  Two rules this file keeps, both learned from the replies themselves rather
//  than from the spec:
//
//  * **No `convertFromSnakeCase`.** The replies are snake case, but an edit
//    inside one is the `Sidecar` JSON verbatim, and `Sidecar.swift` owns its
//    keys. A decoder strategy rewrites every key in the document, the edit's
//    included: today's sidecar keys are camelCase and would pass, but the
//    first one spelled with an underscore would stop decoding without a word,
//    and the frame would open with that setting reset. Every type here spells
//    its keys out instead.
//  * **An edit travels as bytes.** `edit.put` splices `JSONEncoder`'s output
//    into the request unchanged, and `edit.get` decodes `Sidecar` straight out
//    of the reply, so a Double is never re-printed by `JSONSerialization` on
//    its way through. `LibraryTests` pins the round trip as identical.

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
        let result: T?
        let error: ErrorBody?
    }

    private struct ErrorBody: Decodable {
        let code: String
        let message: String
        let revision: Int?

        enum CodingKeys: String, CodingKey { case code, message, data }
        private struct Payload: Decodable { let revision: Int? }

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

struct SDKVersion: Decodable, Sendable, Equatable {
    let version: String
    let abi: Int
    let schema: Int
}

enum LibraryKind: String, Codable, Sendable, Equatable {
    case catalog, session
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
            case kind, path, format
            case documentUUID = "document_uuid", syncedAt = "synced_at"
        }

        var isCaptureOne: Bool { kind == "capture_one" }
    }

    struct Counts: Decodable, Sendable, Equatable {
        let images: Int
        let variants: Int?
        let edits: Int?
    }

    let uuid: String
    let kind: LibraryKind
    let name: String
    let path: String
    let origin: Origin
    let counts: Counts
}

struct LibraryHandle: Decodable, Sendable {
    let library: String
    let info: LibraryInfo
}

struct LibraryLink: Decodable, Sendable {
    let library: String
    let info: LibraryInfo
    let sync: LibrarySyncReport?
}

struct LibrarySyncReport: Decodable, Sendable, Equatable {
    struct Table: Decodable, Sendable, Equatable {
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
        case document, format, counts, supported, reason
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

    var id: String { uuid }

    enum CodingKeys: String, CodingKey {
        case uuid, parent, kind, name, position, origin, editable, folder
        case imageCount = "image_count"
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
        case uuid, position, rating, origin
        case colorTag = "color_tag", editRevision = "edit_revision"
    }
}

struct LibraryImage: Decodable, Sendable, Equatable, Identifiable {
    struct Camera: Decodable, Sendable, Equatable {
        let make: String?
        let model: String?
        let lens: String?
    }
    struct Exposure: Decodable, Sendable, Equatable {
        let iso: Double?
        let aperture: Double?
        let shutter: Double?
        let focalLength: Double?
        let compensation: Double?

        enum CodingKeys: String, CodingKey {
            case iso, aperture, shutter, compensation
            case focalLength = "focal_length"
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

    var id: String { uuid }
    var url: URL { URL(fileURLWithPath: path) }
    var isOffline: Bool { exists == false }
    var isCaptureOne: Bool { origin == "capture_one" }
    var hasEdit: Bool { variants.contains(where: \.hasEdit) }

    enum CodingKeys: String, CodingKey {
        case uuid, path, kind, rating, trashed, origin, exists, variants, width, height, camera, exposure
        case fileName = "file_name", colorTag = "color_tag", capturedLocal = "captured_local"
        case fileSize = "file_size"
    }
}

struct LibraryImagePage: Decodable, Sendable {
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
            enum CodingKeys: String, CodingKey { case rating; case colorTag = "color_tag" }
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
            case uuid, position, rating, local
            case colorTag = "color_tag", captureOne = "capture_one"
            case editRevision = "edit_revision", editModifiedAt = "edit_modified_at"
        }
    }
    struct Album: Decodable, Sendable, Equatable {
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
        case uuid, path, kind, exists, width, height, camera, exposure, origin, variants, albums
        case fileName = "file_name", capturedLocal = "captured_local", fileSize = "file_size"
    }
}

struct LibraryLookup: Decodable, Sendable {
    struct Result: Decodable, Sendable {
        struct Match: Decodable, Sendable { let image: String; let variant: String? }
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
        case uuid, path, volume, relinked, online
        case imageCount = "image_count"
    }
}

struct LibraryEdit: Decodable, Sendable {
    /// 0 = none.
    let revision: Int
    let edit: Sidecar?
}

struct LibraryEditWrite: Decodable, Sendable {
    let revision: Int
}

struct LibraryNewVariant: Decodable, Sendable {
    let variant: String
    let position: Int
    let editCopied: Bool?

    enum CodingKeys: String, CodingKey { case variant, position; case editCopied = "edit_copied" }
}

struct LibraryAdd: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let path: String?
        let image: String?
        let variant: String?
        let existing: Bool?
        let storedAt: String?
        let error: String?
        enum CodingKeys: String, CodingKey {
            case path, image, variant, existing, error
            case storedAt = "stored_at"
        }
    }
    let added: Int
    let results: [Item]
}

struct LibraryNewCollection: Decodable, Sendable {
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
        case location, path, role, exists
        case relativePath = "relative_path", outsideSession = "outside_session", imageCount = "image_count"
    }
}

struct SessionFolders: Decodable, Sendable {
    let root: String?
    let folders: [SessionFolder]
}

struct SessionScan: Decodable, Sendable, Equatable {
    let seen: Int
    let added: Int
    let missing: Int
}

struct SessionMove: Decodable, Sendable {
    struct Moved: Decodable, Sendable { let image: String; let from: String?; let to: String? }
    let moved: [Moved]
}

struct SessionTrashPlan: Decodable, Sendable {
    struct File: Decodable, Sendable { let image: String; let path: String }
    let files: [File]
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
        struct R: Decodable { let collections: [LibraryCollection] }
        return try await call("collections.list", R.self, [("library", .string(library))]).collections
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
        struct R: Decodable { let locations: [LibraryLocation] }
        return try await call("locations.list", R.self, [("library", .string(library))]).locations
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

        var value: LibraryValue {
            let meta: [(String, LibraryValue?)] = [
                ("captured_local", capturedLocal.map { .string($0) }),
                ("width", width.map { .int($0) }), ("height", height.map { .int($0) }),
                ("camera_make", cameraMake.map { .string($0) }), ("camera_model", cameraModel.map { .string($0) }),
                ("lens", lens.map { .string($0) }),
            ]
            let present = meta.compactMap { k, v in v.map { (k, $0) } }
            return present.isEmpty ? .string(url.path)
                : .object([("path", .string(url.path)), ("metadata", .object(present))])
        }
    }

    func add(_ library: String, _ items: [AddItem], copy: Bool, collection: String? = nil) async throws -> LibraryAdd {
        try await call("images.add", LibraryAdd.self, [
            ("library", .string(library)), ("items", .array(items.map(\.value))),
            ("mode", .string(copy ? "copy" : "reference")), ("collection", collection.map { .string($0) }),
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
    enum Sort: String, Sendable, CaseIterable { case captured, imported, name, rating, added }

    var collection: String?
    var recursive = true
    var minRating: Int?
    var colorTags: [Int] = []
    var text = ""
    /// SpektraLab's own filter: developed (has an edit) or not.
    var hasEdit: Bool?
    var sort: Sort = .captured
    var descending = false

    var isFiltered: Bool { minRating != nil || !colorTags.isEmpty || !text.isEmpty || hasEdit != nil }

    var pairs: [(String, LibraryValue?)] {
        var filter: [(String, LibraryValue)] = []
        if let minRating { filter.append(("min_rating", .int(minRating))) }
        if !colorTags.isEmpty { filter.append(("color_tags", .array(colorTags.map { .int($0) }))) }
        if !text.isEmpty { filter.append(("text", .string(text))) }
        if let hasEdit { filter.append(("has_edit", .bool(hasEdit))) }
        return [
            ("collection", collection.map { .string($0) }),
            ("recursive", collection == nil ? nil : .bool(recursive)),
            ("filter", filter.isEmpty ? nil : .object(filter)),
            ("sort", .string(sort.rawValue)),
            ("descending", descending ? .bool(true) : nil),
            ("check_files", .bool(true)),
        ]
    }
}
