//  Ratings.swift — a star rating (0–5) per photograph, Lightroom-style.
//
//  Kept apart from the sidecar on purpose. A sidecar is a develop record, and
//  a rating is a culling decision made before any development; writing one
//  into the other would also create a sidecar (with every default it carries)
//  for a frame nobody has developed.
//
//  **A small SQLite catalog, not a JSON file.** The first version of this was
//  one JSON dictionary keyed by `Sidecar.key(for:)`, and review found three
//  ways it loses or misplaces ratings (PR #83):
//
//   - *Rename and move.* The key is the path, so renaming `_DSC2949.NEF`
//     dropped its rating — and the next file to take the old name inherited
//     it, which is worse: a photograph shows stars nobody gave it.
//   - *One file, every rating.* Each write rewrote the whole table, and an
//     unreadable file decoded as an empty table, so the next star written
//     replaced every rating with that one star, silently.
//   - *Two writers.* Two app instances (or a test host beside the app) each
//     wrote back their own snapshot, and the last one won.
//
//  The catalog fixes each at its own layer. Every write is one row in one
//  transaction (WAL, so a second process waits and then sees it). A file that
//  will not open or fails `quick_check` is moved aside, never overwritten.
//  And a row remembers *which file* it was written for, not only where it
//  was, under the same rules `Sidecar.Source` uses for develop settings:
//
//   - **volume + file ID + size** recognises a file renamed or moved within
//     one disk. The volume is its UUID, not `st_dev`, so an external disk
//     that mounts with a different device number is still the same disk.
//   - **A row is only trusted at its path while the file there is still the
//     one it was written for.** A different file at a reused name reads as
//     unrated; the old row stays to be found again by its own file.
//   - **Content is not identity**, for the reason `Sidecar.Source` gives:
//     byte-identical copies are two frames a photographer may rate
//     differently. A copy, or a move to another disk, starts unrated. The
//     head digest is still recorded, because it is how the import culler
//     recognises a suspected duplicate — as a warning, never as a match.
//
//  Main-actor only, like every reader. Lookups are memoised per path for the
//  session (the filmstrip filter asks for every frame on every redraw) and
//  the memo is dropped on any write and whenever a folder is opened.

import Foundation
import CryptoKit
import SQLite3
import os

@MainActor
enum Ratings {
    /// Posted after a rating changes; `object` is the image URL.
    static let didChange = Notification.Name("SpektraLab.Ratings.didChange")

    static let range = 0...5

    /// The catalog, under the sidecar store's parent (tests get their own
    /// directory because `Sidecar.storeDirectory` is redirected under XCTest).
    static var fileURL: URL {
        Sidecar.storeDirectory.deletingLastPathComponent().appending(path: "Catalog.sqlite")
    }

    /// 0 when the frame was never rated, or the catalog cannot be read.
    static func rating(for image: URL) -> Int {
        let path = image.standardizedFileURL.path
        if let memo = memo[path] { return memo }
        let stars = catalog()?.row(for: image)?.rating ?? 0
        memo[path] = stars
        return stars
    }

    /// Set (0 clears). Out-of-range values are clamped.
    static func set(_ stars: Int, for image: URL) {
        let stars = min(max(stars, range.lowerBound), range.upperBound)
        guard let db = catalog() else { return }
        let row = db.row(for: image)
        guard (row?.rating ?? 0) != stars else { return }
        let ok: Bool
        if stars == 0 {
            ok = row.map { db.delete(id: $0.id) } ?? true
        } else {
            ok = db.write(stars, for: image, replacing: row?.id)
        }
        memo = [:]
        guard ok else { return }
        NotificationCenter.default.post(name: didChange, object: image)
    }

    /// Paths of other, existing files the catalog knows with this exact size
    /// and head digest. For the import culler's duplicate warning only.
    static func knownCopies(size: Int, headDigest: String) -> [String] {
        catalog()?.paths(size: size, headDigest: headDigest) ?? []
    }

    /// Forget the memoised lookups, so files renamed or replaced while the
    /// app was looking elsewhere are recognised again. `Session.open(urls:)`.
    static func forgetLookups() {
        memo = [:]
    }

    /// Forget the memo and the open catalog (tests, a newly opened folder, or
    /// after the store moves).
    static func reload() {
        memo = [:]
        open = nil
    }

    // MARK: - private

    private static var memo: [String: Int] = [:]
    private static var open: Catalog?
    private static let logger = Logger(subsystem: "SpektraLab", category: "ratings")

    private static func catalog() -> Catalog? {
        let url = fileURL
        if let open, open.url == url { return open }
        open = Catalog(url: url, logger: logger)
        return open
    }
}

/// The SQLite file itself. One connection, main actor.
@MainActor
private final class Catalog {
    struct Row { let id: Int64; let rating: Int }

    let url: URL
    /// Unchecked only so `deinit` can close it; every other use is on the
    /// main actor with the rest of the class.
    nonisolated(unsafe) private var db: OpaquePointer?
    private let logger: Logger
    /// Volume UUIDs by `st_dev`, for the session: one resource lookup per disk.
    private var volumes: [Int: String] = [:]

    private static let schemaVersion: Int32 = 1

    init?(url: URL, logger: Logger) {
        self.url = url
        self.logger = logger
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if !connect() {
            // Unreadable or damaged: keep it for inspection, start a new one.
            // Never written over — whatever is in there is the user's.
            setAside()
            guard connect() else { return nil }
        }
    }

    deinit { sqlite3_close_v2(db) }

    private func connect() -> Bool {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            logger.error("catalog open failed: \(String(cString: sqlite3_errmsg(handle)), privacy: .public)")
            sqlite3_close_v2(handle)
            return false
        }
        db = handle
        sqlite3_busy_timeout(handle, 2000)
        guard scalarText("PRAGMA quick_check") == "ok",
              exec("PRAGMA journal_mode=WAL"),
              migrate() else {
            logger.error("catalog failed its check: \(self.url.path, privacy: .public)")
            sqlite3_close_v2(handle)
            db = nil
            return false
        }
        return true
    }

    private func setAside() {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            let to = URL(fileURLWithPath: url.path + ".unreadable-\(stamp)" + suffix)
            try? FileManager.default.moveItem(at: from, to: to)
        }
        logger.error("catalog set aside as .unreadable-\(stamp, privacy: .public)")
    }

    private func migrate() -> Bool {
        let version = Int32(scalarInt("PRAGMA user_version") ?? 0)
        if version == Self.schemaVersion { return true }
        guard version == 0 else {
            // Written by a newer build. Reading it under a schema this build
            // does not know could misread it; leave it alone, rate nothing.
            logger.error("catalog schema \(version) is newer than \(Self.schemaVersion)")
            return false
        }
        return transaction {
            exec("""
                CREATE TABLE IF NOT EXISTS photo (
                    id          INTEGER PRIMARY KEY,
                    path        TEXT    NOT NULL,
                    volume      TEXT,
                    file_id     INTEGER,
                    size        INTEGER,
                    head_digest TEXT,
                    rating      INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
                    modified    REAL    NOT NULL
                )
                """)
            && exec("CREATE INDEX IF NOT EXISTS photo_path ON photo(path)")
            && exec("CREATE INDEX IF NOT EXISTS photo_file ON photo(volume, file_id)")
            && exec("CREATE INDEX IF NOT EXISTS photo_content ON photo(size, head_digest)")
            && exec("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    // MARK: identity

    struct Identity: Equatable {
        var volume: String?
        var fileID: Int64?
        var size: Int64?
    }

    private func identity(ofPath path: String) -> Identity? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Identity(volume: volume(dev: Int(st.st_dev), path: path),
                        fileID: Int64(bitPattern: UInt64(st.st_ino)),
                        size: Int64(st.st_size))
    }

    private func volume(dev: Int, path: String) -> String {
        if let known = volumes[dev] { return known }
        let uuid = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]))?
            .volumeUUIDString
        let id = uuid ?? "dev:\(dev)"
        volumes[dev] = id
        return id
    }

    private static func headDigest(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: Sidecar.headSampleBytes) else { return nil }
        return SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the file now at `path` is the file `stored` was written for.
    /// Unknown on either side (a volume without file IDs) trusts the path.
    private static func same(_ stored: Identity, _ current: Identity?) -> Bool {
        guard let current, let a = stored.fileID, let b = current.fileID,
              let va = stored.volume, let vb = current.volume else { return true }
        return a == b && va == vb
    }

    // MARK: rows

    /// The row for the file at `image`: by path while it is still that file,
    /// else by the file itself if it was renamed or moved on its disk (the
    /// row is re-keyed to the new path, so the move costs one query once).
    func row(for image: URL) -> Row? {
        let path = image.standardizedFileURL.path
        let current = identity(ofPath: path)
        for (id, rating, stored) in rows(where: "path = ?", [.text(path)])
        where Self.same(stored, current) {
            return Row(id: id, rating: rating)
        }
        guard let current, let volume = current.volume, let fileID = current.fileID else { return nil }
        let candidates = rows(where: "volume = ? AND file_id = ? AND size = ?",
                              [.text(volume), .int(fileID), .int(current.size ?? -1)],
                              withPath: true)
        for c in candidates {
            // The file this row was written for must no longer be at its old
            // path; otherwise this is an inode reused or a second hard link,
            // not a move. (A rename swap passes: the old path now holds the
            // other file.)
            if let old = c.path, let there = identity(ofPath: old), Self.same(c.stored, there) { continue }
            guard run("UPDATE photo SET path = ? WHERE id = ?", [.text(path), .int(c.id)]) else { return nil }
            return Row(id: c.id, rating: c.rating)
        }
        return nil
    }

    func write(_ stars: Int, for image: URL, replacing id: Int64?) -> Bool {
        let path = image.standardizedFileURL.path
        let current = identity(ofPath: path)
        let digest = Self.headDigest(of: path)
        let now = Date().timeIntervalSince1970
        let values: [Value] = [.text(path), current?.volume.map(Value.text) ?? .null,
                               current?.fileID.map(Value.int) ?? .null,
                               current?.size.map(Value.int) ?? .null,
                               digest.map(Value.text) ?? .null, .int(Int64(stars)), .real(now)]
        return transaction {
            if let id {
                return run("""
                    UPDATE photo SET path = ?, volume = ?, file_id = ?, size = ?, head_digest = ?,
                                     rating = ?, modified = ? WHERE id = ?
                    """, values + [.int(id)])
            }
            return run("""
                INSERT INTO photo (path, volume, file_id, size, head_digest, rating, modified)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, values)
        }
    }

    func delete(id: Int64) -> Bool {
        run("DELETE FROM photo WHERE id = ?", [.int(id)])
    }

    func paths(size: Int, headDigest: String) -> [String] {
        rows(where: "size = ? AND head_digest = ?", [.int(Int64(size)), .text(headDigest)], withPath: true)
            .compactMap(\.path)
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: SQLite plumbing

    enum Value { case text(String), int(Int64), real(Double), null }

    private func rows(where clause: String, _ values: [Value])
        -> [(id: Int64, rating: Int, stored: Identity)] {
        rows(where: clause, values, withPath: false).map { ($0.id, $0.rating, $0.stored) }
    }

    private func rows(where clause: String, _ values: [Value], withPath: Bool)
        -> [(id: Int64, rating: Int, stored: Identity, path: String?)] {
        var out: [(Int64, Int, Identity, String?)] = []
        _ = query("SELECT id, rating, volume, file_id, size, path FROM photo WHERE \(clause)", values) { s in
            let stored = Identity(volume: Self.text(s, 2), fileID: Self.int(s, 3), size: Self.int(s, 4))
            out.append((sqlite3_column_int64(s, 0), Int(sqlite3_column_int64(s, 1)), stored,
                        withPath ? Self.text(s, 5) : nil))
        }
        return out
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(s, i))
    }

    private static func int(_ s: OpaquePointer, _ i: Int32) -> Int64? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_int64(s, i)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            logger.error("catalog: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
            return false
        }
        return true
    }

    private func run(_ sql: String, _ values: [Value]) -> Bool {
        query(sql, values) { _ in }
    }

    private func transaction(_ body: () -> Bool) -> Bool {
        guard exec("BEGIN IMMEDIATE") else { return false }
        guard body() else { exec("ROLLBACK"); return false }
        guard exec("COMMIT") else { exec("ROLLBACK"); return false }
        return true
    }

    /// Prepare, bind, step every row through `each`. False on any error.
    @discardableResult
    private func query(_ sql: String, _ values: [Value], _ each: (OpaquePointer) -> Void) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            logger.error("catalog: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
            return false
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, v) in values.enumerated() {
            let at = Int32(i + 1)
            switch v {
            case .text(let t): sqlite3_bind_text(stmt, at, t, -1, transient)
            case .int(let n): sqlite3_bind_int64(stmt, at, n)
            case .real(let r): sqlite3_bind_double(stmt, at, r)
            case .null: sqlite3_bind_null(stmt, at)
            }
        }
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: each(stmt)
            case SQLITE_DONE: return true
            default:
                logger.error("catalog: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
                return false
            }
        }
    }

    private func scalarText(_ sql: String) -> String? {
        var out: String?
        query(sql, []) { out = Self.text($0, 0) }
        return out
    }

    private func scalarInt(_ sql: String) -> Int64? {
        var out: Int64?
        query(sql, []) { out = Self.int($0, 0) }
        return out
    }
}
