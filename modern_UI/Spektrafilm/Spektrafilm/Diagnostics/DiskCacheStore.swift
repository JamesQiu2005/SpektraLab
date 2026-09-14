import CryptoKit
import Foundation
import SQLite3

struct DiskCachePayload: Sendable {
    let data: Data
    let width: Int
    let height: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let format: String
    let kind: CacheKind
    let costMs: Double
    let hits: Int
}

private struct DiskCacheHeader: Codable, Equatable {
    let version: Int
    let key: CacheKey
    let width: Int
    let height: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let format: String
    let payloadBytes: Int
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One disk cache shared by display decodes and prints. The file is complete
/// before its index row is written; a row without a file is garbage, and a
/// file without a row is collected at launch.
actor DiskCacheStore {
    enum Failure: Error, LocalizedError {
        case database(String)
        case invalidDimensions
        case invalidPayload
        case corrupt

        var errorDescription: String? {
            switch self {
            case .database(let why): "cache database: \(why)"
            case .invalidDimensions: "cache dimensions are invalid"
            case .invalidPayload: "cache payload length does not match its dimensions"
            case .corrupt: "cache entry is corrupt"
            }
        }
    }

    nonisolated let root: URL
    nonisolated let capBytes: UInt64
    nonisolated(unsafe) private let database: OpaquePointer

    init(root: URL, capBytes: UInt64 = 16_000_000_000) throws {
        self.root = root
        self.capBytes = capBytes
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var db: OpaquePointer?
        let dbURL = root.appending(path: "index.sqlite")
        guard sqlite3_open_v2(dbURL.path, &db,
                              SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let db else {
            throw Failure.database("could not open \(dbURL.path)")
        }
        database = db
        sqlite3_busy_timeout(db, 5_000)
        try Self.execute(on: db, """
            CREATE TABLE IF NOT EXISTS entries (
              key TEXT PRIMARY KEY,
              kind TEXT NOT NULL,
              path TEXT NOT NULL,
              width INTEGER NOT NULL,
              height INTEGER NOT NULL,
              source_width INTEGER NOT NULL DEFAULT 0,
              source_height INTEGER NOT NULL DEFAULT 0,
              format TEXT NOT NULL,
              bytes INTEGER NOT NULL,
              cost_ms REAL NOT NULL,
              hits INTEGER NOT NULL DEFAULT 0,
              priority REAL NOT NULL,
              created_at REAL NOT NULL,
              used_at REAL NOT NULL
            )
        """)
        try Self.execute(on: db, """
            CREATE INDEX IF NOT EXISTS entries_priority ON entries(priority);
        """)
        try Self.execute(on: db, """
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value REAL NOT NULL);
        """)
        try Self.execute(on: db, """
            INSERT OR IGNORE INTO meta(key, value) VALUES('clock', 0);
        """)
    }

    deinit {
        sqlite3_close(database)
    }

    func store(key: CacheKey, data: Data, width: Int, height: Int,
               sourceWidth: Int? = nil, sourceHeight: Int? = nil,
               format: String, costMs: Double) throws {
        let sourceWidth = sourceWidth ?? width
        let sourceHeight = sourceHeight ?? height
        guard width > 0, height > 0, sourceWidth > 0, sourceHeight > 0 else {
            throw Failure.invalidDimensions
        }
        let expected = width * height * 8
        guard data.count == expected else { throw Failure.invalidPayload }

        let header = DiskCacheHeader(version: CacheKey.formatVersion, key: key,
                                     width: width, height: height,
                                     sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                                     format: format, payloadBytes: data.count)
        let headerData = try JSONEncoder().encode(header)
        var file = Data()
        var headerLength = UInt32(headerData.count).littleEndian
        withUnsafeBytes(of: &headerLength) { file.append(contentsOf: $0) }
        file.append(headerData)
        file.append(data)

        let destination = path(for: key)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try file.write(to: temporary)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }

        let now = Date().timeIntervalSince1970
        let clock = try currentClock()
        let priority = gdsfPriority(hits: 0, costMs: costMs, bytes: data.count, clock: clock)
        try execute("""
            INSERT INTO entries
              (key, kind, path, width, height, source_width, source_height,
               format, bytes, cost_ms, hits, priority, created_at, used_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
              path=excluded.path, width=excluded.width, height=excluded.height,
              source_width=excluded.source_width, source_height=excluded.source_height,
              format=excluded.format, bytes=excluded.bytes, cost_ms=excluded.cost_ms,
              priority=excluded.priority, used_at=excluded.used_at
        """) { statement in
            self.bind(self.encoded(key), 1, statement)
            self.bind(key.kind.rawValue, 2, statement)
            self.bind(destination.path, 3, statement)
            sqlite3_bind_int64(statement, 4, Int64(width))
            sqlite3_bind_int64(statement, 5, Int64(height))
            sqlite3_bind_int64(statement, 6, Int64(sourceWidth))
            sqlite3_bind_int64(statement, 7, Int64(sourceHeight))
            self.bind(format, 8, statement)
            sqlite3_bind_int64(statement, 9, Int64(data.count))
            sqlite3_bind_double(statement, 10, costMs)
            sqlite3_bind_double(statement, 11, priority)
            sqlite3_bind_double(statement, 12, now)
            sqlite3_bind_double(statement, 13, now)
        }
        try evictIfNeeded()
    }

    func load(_ key: CacheKey) throws -> DiskCachePayload? {
        var path: String?
        var width = 0
        var height = 0
        var sourceWidth = 0
        var sourceHeight = 0
        var format = ""
        var bytes = 0
        var costMs = 0.0
        var hits = 0

        try query("""
            SELECT path, width, height, source_width, source_height,
                   format, bytes, cost_ms, hits
            FROM entries WHERE key = ?
        """, bind: { self.bind(self.encoded(key), 1, $0) }) { row in
            path = self.text(row, 0)
            width = Int(sqlite3_column_int64(row, 1))
            height = Int(sqlite3_column_int64(row, 2))
            sourceWidth = Int(sqlite3_column_int64(row, 3))
            sourceHeight = Int(sqlite3_column_int64(row, 4))
            format = self.text(row, 5) ?? ""
            bytes = Int(sqlite3_column_int64(row, 6))
            costMs = sqlite3_column_double(row, 7)
            hits = Int(sqlite3_column_int64(row, 8))
        }
        guard let path else { return nil }
        do {
            let file = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            let decoded = try decodeHeader(file)
            let header = decoded.header
            guard header.version == CacheKey.formatVersion, header.key == key,
                  header.width == width, header.height == height,
                  header.sourceWidth == sourceWidth,
                  header.sourceHeight == sourceHeight,
                  header.format == format, header.payloadBytes == bytes,
                  file.count == decoded.byteCount + header.payloadBytes else {
                throw Failure.corrupt
            }
            let payload = file.subdata(in: decoded.byteCount..<file.count)
            guard payload.count == width * height * 8 else { throw Failure.corrupt }
            let nextHits = hits + 1
            let now = Date().timeIntervalSince1970
            let priority = gdsfPriority(hits: nextHits, costMs: costMs,
                                        bytes: bytes, clock: try currentClock())
            try execute("""
                UPDATE entries SET hits = ?, priority = ?, used_at = ? WHERE key = ?
            """) {
                sqlite3_bind_int64($0, 1, Int64(nextHits))
                sqlite3_bind_double($0, 2, priority)
                sqlite3_bind_double($0, 3, now)
                self.bind(self.encoded(key), 4, $0)
            }
            return DiskCachePayload(data: payload, width: width, height: height,
                                    sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                                    format: format, kind: key.kind,
                                    costMs: costMs, hits: nextHits)
        } catch {
            try remove(key: key, path: path)
            return nil
        }
    }

    func garbageCollect() throws {
        var rows: [(String, String)] = []
        try query("SELECT key, path FROM entries") { row in
            guard let key = self.text(row, 0), let path = self.text(row, 1) else { return }
            rows.append((key, path))
        }
        var indexed = Set<String>()
        for (key, path) in rows {
            if FileManager.default.fileExists(atPath: path) {
                indexed.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
            } else {
                try execute("DELETE FROM entries WHERE key = ?") {
                    self.bind(key, 1, $0)
                }
            }
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let file as URL in enumerator
        where file.pathExtension == "bin" || file.pathExtension == "tmp" {
            if !indexed.contains(file.standardizedFileURL.path) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func totalBytes() throws -> UInt64 {
        var total: UInt64 = 0
        try query("SELECT COALESCE(SUM(bytes), 0) FROM entries") { row in
            total = UInt64(sqlite3_column_int64(row, 0))
        }
        return total
    }

    private func evictIfNeeded() throws {
        var total = try totalBytes()
        guard total > capBytes else { return }
        while total > capBytes {
            var candidate: (key: String, path: String, bytes: Int, priority: Double)?
            try query("""
                SELECT key, path, bytes, priority FROM entries
                ORDER BY priority ASC, used_at ASC LIMIT 1
            """) { row in
                guard let key = self.text(row, 0), let path = self.text(row, 1) else { return }
                candidate = (key, path, Int(sqlite3_column_int64(row, 2)),
                             sqlite3_column_double(row, 3))
            }
            guard let candidate else { return }
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: candidate.path))
            try execute("DELETE FROM entries WHERE key = ?") {
                self.bind(candidate.key, 1, $0)
            }
            try setClock(max(try currentClock(), candidate.priority))
            total = try totalBytes()
        }
    }

    private func remove(key: CacheKey, path: String) throws {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        try execute("DELETE FROM entries WHERE key = ?") {
            self.bind(self.encoded(key), 1, $0)
        }
    }

    private func path(for key: CacheKey) -> URL {
        let digest = SHA256.hash(data: Data(encoded(key).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return root.appending(path: String(digest.prefix(2)))
            .appending(path: "\(digest).bin")
    }

    private func encoded(_ key: CacheKey) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try! encoder.encode(key), as: UTF8.self)
    }

    private func decodeHeader(_ data: Data) throws -> (header: DiskCacheHeader, byteCount: Int) {
        guard data.count >= 4 else { throw Failure.corrupt }
        let length = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        let count = Int(UInt32(littleEndian: length))
        guard count > 0, data.count >= 4 + count else { throw Failure.corrupt }
        let header = try JSONDecoder().decode(
            DiskCacheHeader.self,
            from: data.subdata(in: 4..<(4 + count))
        )
        return (header, 4 + count)
    }

    private func currentClock() throws -> Double {
        var clock = 0.0
        try query("SELECT value FROM meta WHERE key = 'clock'") { row in
            clock = sqlite3_column_double(row, 0)
        }
        return clock
    }

    private func setClock(_ value: Double) throws {
        try execute("INSERT OR REPLACE INTO meta(key, value) VALUES('clock', ?)") {
            sqlite3_bind_double($0, 1, value)
        }
    }

    private func execute(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }) throws {
        try Self.execute(on: database, sql, bind: bind)
    }

    private static func execute(on database: OpaquePointer, _ sql: String,
                                bind: (OpaquePointer) -> Void = { _ in }) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw Failure.database(lastError(database)) }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw Failure.database(lastError(database))
        }
    }

    private func query(_ sql: String, bind: (OpaquePointer) -> Void = { _ in },
                       _ row: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw Failure.database(lastError) }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    private func bind(_ value: String, _ index: Int32, _ statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private static func lastError(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    private var lastError: String {
        Self.lastError(database)
    }
}
