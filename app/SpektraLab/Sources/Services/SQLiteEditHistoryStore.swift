//  SQLiteEditHistoryStore.swift — the edit history on disk: `EditHistory/history.sqlite`, beside `library.json`
//  (PRD-F §2). The system's `libsqlite3` (public domain): no new dependency.
//
//  Why SQLite and not a JSON file per frame: a step and its cursor are written in **one transaction** (a crash
//  loses at most the step in flight, never a cursor on a state that is not there); the 256-step trim is a
//  `DELETE`; Settings' size is one query; Clear All is one statement; and it is spklib's engine, so phase 2 (a
//  catalog that carries its history, §2.1) is a table copy, not a format change.
//
//  The file (schema 2, `PRAGMA user_version`; schema 1 is read and moved to it):
//
//      history_frame(frame TEXT PRIMARY KEY, cursor INTEGER, earlier INTEGER)       -- one row a frame
//      history_step(frame TEXT, seq INTEGER, at REAL, origin TEXT, label TEXT, state BLOB,
//                   PRIMARY KEY(frame, seq))                                       -- the base and its steps
//
//  `label` is `HistoryLabel`'s JSON; `state` is `HistoryCodec`'s compressed `DevelopRevision`; `at` is seconds
//  since 1970. The base is the frame's lowest `seq`. WAL, `synchronous = NORMAL`: a transaction is durable
//  against the app's crash (the case the owner named), not against the power going.
//
//  **A newer build's file** (`user_version` above `schema`) is opened read-only once, to read that number, and
//  then never again: every call throws `newerSchema`, and nothing in the file is changed (§3.5). The file is
//  opened on the first call, on the actor, never at launch on the main thread.

import Foundation
import SQLite3

actor SQLiteEditHistoryStore: EditHistoryStore {
    /// This build's schema.
    static let schema: Int32 = 2
    /// `<Application Support>/<bundle id>/EditHistory/history.sqlite`.
    static func file(in root: URL) -> URL {
        root.appendingPathComponent("EditHistory", isDirectory: true).appendingPathComponent("history.sqlite")
    }

    nonisolated let limit: Int
    let url: URL
    private var db: OpaquePointer?
    /// Why the file is not used: a newer schema, or a failure to open it.
    private var refusal: EditHistoryError?

    init(url: URL, limit: Int = 256) {
        self.url = url
        self.limit = max(1, limit)
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    // MARK: the file

    private func database() throws -> OpaquePointer {
        if let db { return db }
        if let refusal { throw refusal }
        do {
            let opened = try openFile()
            db = opened
            return opened
        } catch let error as EditHistoryError {
            refusal = error
            throw error
        }
    }

    private func openFile() throws -> OpaquePointer {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            // Read the schema before anything can write: a newer build's file is left as it is.
            var ro: OpaquePointer?
            guard sqlite3_open_v2(url.path, &ro, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let ro else {
                let message = ro.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
                sqlite3_close_v2(ro)
                throw EditHistoryError.sqlite(message)
            }
            let found = Self.userVersion(ro)
            sqlite3_close_v2(ro)
            if found > Self.schema { throw EditHistoryError.newerSchema(found: Int(found), known: Int(Self.schema)) }
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(handle)
            throw EditHistoryError.sqlite(message)
        }
        do {
            sqlite3_busy_timeout(handle, 2000)
            try Self.exec(handle, "PRAGMA journal_mode = WAL")
            try Self.exec(handle, "PRAGMA synchronous = NORMAL")
            // The log is folded into the file every 64 pages (256 KB) and cut back to 256 KB when it is: left to
            // SQLite's 1000 pages and no limit, 300 steps of 0.3 MB left a 3.7 MB set on disk (PRD-F part 1's
            // measurement), most of it log, and Settings' figure would have been the log's.
            try Self.exec(handle, "PRAGMA journal_size_limit = 262144")
            try Self.exec(handle, "PRAGMA wal_autocheckpoint = 64")
            let found = Self.userVersion(handle)
            // A newer build may have made the file between the two opens.
            if found > Self.schema { throw EditHistoryError.newerSchema(found: Int(found), known: Int(Self.schema)) }
            if found < Self.schema {
                try Self.exec(handle, "BEGIN IMMEDIATE")
                // Schema 1 (part 1's, never released) kept its steps WITHOUT ROWID: a ~1.1 KB state is past such a
                // table's 1 KB of a row in its page, so every step took an overflow page of 4 KB, and 257 states of
                // 266 KB took 1.2 MB (measured 2026-11-13). A table with a row id keeps the same row in its page.
                if found == 1 { try Self.exec(handle, "ALTER TABLE history_step RENAME TO history_step_1") }
                try Self.exec(handle, """
                    CREATE TABLE IF NOT EXISTS history_frame(
                        frame TEXT PRIMARY KEY NOT NULL,
                        cursor INTEGER NOT NULL,
                        earlier INTEGER NOT NULL DEFAULT 0);
                    CREATE TABLE IF NOT EXISTS history_step(
                        frame TEXT NOT NULL,
                        seq INTEGER NOT NULL,
                        at REAL NOT NULL,
                        origin TEXT NOT NULL,
                        label TEXT NOT NULL,
                        state BLOB NOT NULL,
                        PRIMARY KEY(frame, seq));
                    """)
                if found == 1 {
                    try Self.exec(handle, "INSERT INTO history_step SELECT frame, seq, at, origin, label, state FROM history_step_1; DROP TABLE history_step_1;")
                }
                try Self.exec(handle, "PRAGMA user_version = \(Self.schema)")
                try Self.exec(handle, "COMMIT")
                if found == 1 { try? Self.exec(handle, "VACUUM") }
            }
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
        return handle
    }

    private static func userVersion(_ db: OpaquePointer) -> Int32 {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(error)
            throw EditHistoryError.sqlite(message)
        }
    }

    /// `body` in one transaction: committed if it returns, rolled back if it throws.
    private func transaction<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        let db = try database()
        try Self.exec(db, "BEGIN IMMEDIATE")
        do {
            let value = try body(db)
            try Self.exec(db, "COMMIT")
            return value
        } catch {
            try? Self.exec(db, "ROLLBACK")
            throw error
        }
    }

    // MARK: statements

    /// A prepared statement, its values bound in order.
    private struct Statement {
        let handle: OpaquePointer
        let db: OpaquePointer

        init(_ db: OpaquePointer, _ sql: String, _ values: [Value] = []) throws {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw EditHistoryError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            handle = stmt
            self.db = db
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, value) in values.enumerated() {
                let at = Int32(i + 1)
                switch value {
                case .int(let v): sqlite3_bind_int64(stmt, at, Int64(v))
                case .double(let v): sqlite3_bind_double(stmt, at, v)
                case .text(let v): sqlite3_bind_text(stmt, at, v, -1, transient)
                case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, at, $0.baseAddress, Int32($0.count), transient) }
                }
            }
        }

        enum Value { case int(Int), double(Double), text(String), blob(Data) }

        /// Each row, until there are none.
        func rows(_ each: (OpaquePointer) throws -> Void) throws {
            defer { sqlite3_finalize(handle) }
            while true {
                let rc = sqlite3_step(handle)
                if rc == SQLITE_DONE { return }
                guard rc == SQLITE_ROW else { throw EditHistoryError.sqlite(String(cString: sqlite3_errmsg(db))) }
                try each(handle)
            }
        }

        func run() throws { try rows { _ in } }
    }

    private static func blob(_ stmt: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(stmt, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }

    // MARK: a frame's rows

    private struct Shape { var cursor: Int; var earlier: Bool; var base: Int; var last: Int }

    private func shape(_ db: OpaquePointer, _ frame: String) throws -> Shape? {
        var found: (Int, Bool)?
        try Statement(db, "SELECT cursor, earlier FROM history_frame WHERE frame = ?", [.text(frame)]).rows {
            found = (Int(sqlite3_column_int64($0, 0)), sqlite3_column_int($0, 1) != 0)
        }
        guard let found else { return nil }
        var range: (Int, Int)?
        try Statement(db, "SELECT MIN(seq), MAX(seq), COUNT(*) FROM history_step WHERE frame = ?", [.text(frame)]).rows {
            if sqlite3_column_int64($0, 2) > 0 { range = (Int(sqlite3_column_int64($0, 0)), Int(sqlite3_column_int64($0, 1))) }
        }
        guard let range else { return nil }
        return Shape(cursor: found.0, earlier: found.1, base: range.0, last: range.1)
    }

    private func stateData(_ db: OpaquePointer, _ frame: String, _ seq: Int) throws -> Data? {
        var data: Data?
        try Statement(db, "SELECT state FROM history_step WHERE frame = ? AND seq = ?", [.text(frame), .int(seq)]).rows {
            data = Self.blob($0, 0)
        }
        return data
    }

    private func setCursor(_ db: OpaquePointer, _ frame: String, _ cursor: Int, earlier: Bool) throws {
        try Statement(db, "INSERT INTO history_frame(frame, cursor, earlier) VALUES(?, ?, ?) "
                          + "ON CONFLICT(frame) DO UPDATE SET cursor = excluded.cursor, earlier = excluded.earlier",
                      [.text(frame), .int(cursor), .int(earlier ? 1 : 0)]).run()
    }

    private func setState(_ db: OpaquePointer, _ frame: String, _ seq: Int, _ data: Data) throws {
        try Statement(db, "UPDATE history_step SET state = ? WHERE frame = ? AND seq = ?", [.blob(data), .text(frame), .int(seq)]).run()
    }

    private func insert(_ db: OpaquePointer, _ frame: String, _ seq: Int, at: Date, origin: HistoryOrigin, label: HistoryLabel, _ data: Data) throws {
        try Statement(db, "INSERT OR REPLACE INTO history_step(frame, seq, at, origin, label, state) VALUES(?, ?, ?, ?, ?, ?)",
                      [.text(frame), .int(seq), .double(at.timeIntervalSince1970), .text(origin.rawValue), .text(HistoryCodec.label(label)),
                       .blob(data)]).run()
    }

    /// The step after the cursor: the states ahead of it dropped, the cursor onto it, the oldest past the limit
    /// dropped (the base then *Earlier edits*). Inside the caller's transaction.
    private func add(_ db: OpaquePointer, _ frame: String, _ shape: inout Shape, at: Date, origin: HistoryOrigin, label: HistoryLabel,
                     _ data: Data) throws {
        try Statement(db, "DELETE FROM history_step WHERE frame = ? AND seq > ?", [.text(frame), .int(shape.cursor)]).run()
        shape.cursor += 1
        shape.last = shape.cursor
        try insert(db, frame, shape.cursor, at: at, origin: origin, label: label, data)
        if shape.last - shape.base > limit {
            shape.base = shape.last - limit
            shape.earlier = true
            try Statement(db, "DELETE FROM history_step WHERE frame = ? AND seq < ?", [.text(frame), .int(shape.base)]).run()
        }
        try setCursor(db, frame, shape.cursor, earlier: shape.earlier)
    }

    /// The reconciliation guard (PRD-F §3.2), inside the caller's transaction.
    private func reconcile(_ db: OpaquePointer, _ frame: String, _ shape: inout Shape, to current: DevelopRevision,
                           at: Date) throws -> HistoryWindow.Reconciled {
        guard let data = try stateData(db, frame, shape.cursor) else { return .empty }
        let cursorState = try HistoryCodec.decode(data)
        if cursorState.isSameEdit(as: current) {
            let now = try HistoryCodec.encode(current)
            if now != data { try setState(db, frame, shape.cursor, now) }
            return .agreed
        }
        for seq in HistoryReconcile.searchOrder(cursor: shape.cursor, base: shape.base, last: shape.last) {
            guard let d = try stateData(db, frame, seq), try HistoryCodec.decode(d).isSameEdit(as: current) else { continue }
            let from = shape.cursor
            shape.cursor = seq
            try setCursor(db, frame, seq, earlier: shape.earlier)
            return .movedCursor(from: from)
        }
        try add(db, frame, &shape, at: at, origin: .elsewhere, label: .changedElsewhere, try HistoryCodec.encode(current))
        return .addedElsewhere
    }

    private func decoded(_ db: OpaquePointer, _ frame: String, _ seqs: ClosedRange<Int>) throws -> [Int: DevelopRevision] {
        var out: [Int: DevelopRevision] = [:]
        try Statement(db, "SELECT seq, state FROM history_step WHERE frame = ? AND seq BETWEEN ? AND ?",
                      [.text(frame), .int(seqs.lowerBound), .int(seqs.upperBound)]).rows {
            out[Int(sqlite3_column_int64($0, 0))] = try HistoryCodec.decode(Self.blob($0, 1))
        }
        return out
    }

    // MARK: EditHistoryStore

    func open(_ frame: UUID, current: DevelopRevision, radius: Int, at: Date) throws -> HistoryWindow {
        let key = frame.uuidString
        return try transaction { db in
            guard var shape = try shape(db, key) else { return HistoryWindow() }
            let reconciled = try reconcile(db, key, &shape, to: current, at: at)
            let lo = max(shape.base, shape.cursor - radius), hi = max(lo, min(shape.last, shape.cursor + radius))
            return HistoryWindow(baseSeq: shape.base, lastSeq: shape.last, cursorSeq: shape.cursor, baseIsEarlier: shape.earlier,
                                 states: try decoded(db, key, lo...hi), reconciled: reconciled)
        }
    }

    func listing(_ frame: UUID) throws -> HistoryListing? {
        let db = try database()
        let key = frame.uuidString
        guard let shape = try shape(db, key) else { return nil }
        var rows: [HistoryStepInfo] = []
        rows.reserveCapacity(shape.last - shape.base + 1)
        try Statement(db, "SELECT seq, at, origin, label, length(state) FROM history_step WHERE frame = ? ORDER BY seq", [.text(key)]).rows {
            let origin = Self.text($0, 2)
            rows.append(HistoryStepInfo(seq: Int(sqlite3_column_int64($0, 0)), at: Date(timeIntervalSince1970: sqlite3_column_double($0, 1)),
                                        origin: HistoryOrigin(stored: origin), originText: origin,
                                        label: HistoryCodec.label(Self.text($0, 3)), bytes: Int(sqlite3_column_int64($0, 4))))
        }
        guard let base = rows.first else { return nil }
        return HistoryListing(frame: frame, base: base, steps: Array(rows.dropFirst()), cursorSeq: shape.cursor, baseIsEarlier: shape.earlier)
    }

    func state(_ frame: UUID, seq: Int) throws -> DevelopRevision? {
        try stateData(try database(), frame.uuidString, seq).map(HistoryCodec.decode)
    }

    func states(_ frame: UUID, seqs: ClosedRange<Int>) throws -> [Int: DevelopRevision] {
        try decoded(try database(), frame.uuidString, seqs)
    }

    @discardableResult
    func append(_ frame: UUID, _ step: HistoryAppend) throws -> Int? {
        guard step.before != step.after else { return nil }
        // Encoded and compressed before the transaction opens: the write itself is short.
        let before = try HistoryCodec.encode(step.before), after = try HistoryCodec.encode(step.after)
        let key = frame.uuidString
        return try transaction { db in
            var kept: Shape
            if var was = try shape(db, key) {
                if step.mode == .reconciles { _ = try reconcile(db, key, &was, to: step.before, at: step.at) }
                if try stateData(db, key, was.cursor) != before { try setState(db, key, was.cursor, before) }
                kept = was
            } else {
                // A frame's first step: the state it began from is the base, *Original*.
                try Statement(db, "DELETE FROM history_step WHERE frame = ?", [.text(key)]).run()
                try insert(db, key, 0, at: step.at, origin: .elsewhere, label: HistoryCodec.original, before)
                kept = Shape(cursor: 0, earlier: false, base: 0, last: 0)
            }
            try add(db, key, &kept, at: step.at, origin: step.origin, label: step.label, after)
            return kept.cursor
        }
    }

    func move(_ frame: UUID, to seq: Int) throws {
        let key = frame.uuidString
        try transaction { db in
            guard let shape = try shape(db, key) else { return }
            try setCursor(db, key, min(max(seq, shape.base), shape.last), earlier: shape.earlier)
        }
    }

    func amend(_ frame: UUID, current: DevelopRevision) throws {
        let data = try HistoryCodec.encode(current)
        let key = frame.uuidString
        try transaction { db in
            guard let shape = try shape(db, key), try stateData(db, key, shape.cursor) != data else { return }
            try setState(db, key, shape.cursor, data)
        }
    }

    func clear(_ frame: UUID, keeping current: DevelopRevision) throws {
        let data = try HistoryCodec.encode(current)
        let key = frame.uuidString
        try transaction { db in
            guard let shape = try shape(db, key) else { return }
            try Statement(db, "DELETE FROM history_step WHERE frame = ? AND seq <> ?", [.text(key), .int(shape.cursor)]).run()
            try setState(db, key, shape.cursor, data)
            try setCursor(db, key, shape.cursor, earlier: false)
        }
    }

    func remove(_ frames: Set<UUID>) throws {
        guard !frames.isEmpty else { return }
        try transaction { db in
            for frame in frames {
                try Statement(db, "DELETE FROM history_step WHERE frame = ?", [.text(frame.uuidString)]).run()
                try Statement(db, "DELETE FROM history_frame WHERE frame = ?", [.text(frame.uuidString)]).run()
            }
        }
    }

    func bytesOnDisk() throws -> Int64 {
        let fm = FileManager.default
        // What is kept, not what is still in the log: the log folded in first and cut to nothing, where the file is
        // there and this build may write it (never created for this; a newer build's file is measured as it is).
        if fm.fileExists(atPath: url.path), let db = try? database() { try? Self.exec(db, "PRAGMA wal_checkpoint(TRUNCATE)") }
        return [url.path, url.path + "-wal", url.path + "-shm"].reduce(Int64(0)) { sum, path in
            sum + ((try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    func clearAll(except: Set<UUID>) throws {
        try transaction { db in
            if except.isEmpty {
                try Self.exec(db, "DELETE FROM history_step; DELETE FROM history_frame;")
            } else {
                // A handful of open pages at most: their ids inline, as text SQLite quotes itself.
                let kept = except.map { "'" + $0.uuidString + "'" }.joined(separator: ",")
                try Self.exec(db, "DELETE FROM history_step WHERE frame NOT IN (\(kept)); DELETE FROM history_frame WHERE frame NOT IN (\(kept));")
            }
        }
        // The pages freed are given back, and the log folded in: Settings' size is what is left.
        if let db { try? Self.exec(db, "PRAGMA wal_checkpoint(TRUNCATE); VACUUM;") }
    }
}
