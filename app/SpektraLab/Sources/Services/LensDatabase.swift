//  LensDatabase.swift — the lens profiles a person installed (Adobe's, from Camera Raw's folders on their Mac) or
//  added (a single `.lcp`), in one SQLite file in the app's storage: `LensProfiles/lenses.sqlite`, beside
//  `EditHistory/history.sqlite`. The system's `libsqlite3`, in the edit history store's style; no new dependency.
//
//  **No profile ships with the app** (they are Adobe's; the owner, 2026-11-13). What is kept is the numbers
//  `LCP.read` takes from a file, never its XML:
//
//      lcp_file(id, source, name, hash, UNIQUE(source, name))   -- a file: 'adobe-installed' or 'user', its name, SHA-256
//      lens(id, maker, name, UNIQUE(maker, name))                -- one row a lens, by its pretty name
//      variant(id, lens, file, camera JSON, make, model, raw, sensor, rectilinear) -- a body (RAW or not) it was measured on
//      entry(variant, focal, distance, aperture, params JSON)   -- one measured setting: `LCP.Entry`
//      alias(key, lens)                                          -- the lens's names, normalised for matching
//
//  Installing twice changes nothing (a file whose source, name and hash are kept is not read again); a file of the
//  same source and name with another hash replaces its older self (its variants and entries go with it, by
//  `ON DELETE CASCADE`); a lens no variant names any more goes.
//
//  **The maker** a lens is listed under: at install, the folder under Camera Raw's version folder the file sits in
//  (`1.0/Sigma/Sony/…` is Sigma's, `1.0/Voigtlander/Leica/…` Voigtländer's); a file added by itself, or one in
//  `ThirdParty`, by its pretty name's first word where that is a maker's (`knownMakers`, and every maker already
//  listed), else its camera's make's first word.
//
//  **Names are matched normalised** (`matchKey`): lower case, accents folded, "f/" as "f", "mm" after a number
//  dropped, everything but letters, digits, "." and "-" dropped, and a leading maker's word dropped. So EXIF's
//  "RF45mm F1.2 STM" and the pretty "Canon RF 45mm F1.2 STM" are both "rf45f1.2stm". Adobe also records the EXIF
//  string itself (`stCamera:Lens`), which is matched first, as it is.
//
//  An actor: the file is opened on its first call, never on the main thread at launch; `install` parses files on
//  the cooperative pool, 64 at a time, and writes each batch in one transaction.

import CryptoKit
import Foundation
import ImageIO
import SQLite3

actor LensDatabase {
    static let schema: Int32 = 1
    /// `<Application Support>/<bundle id>/LensProfiles/lenses.sqlite`.
    static func file(in root: URL) -> URL {
        root.appendingPathComponent("LensProfiles", isDirectory: true).appendingPathComponent("lenses.sqlite")
    }

    /// Camera Raw's folders of lens profiles that are on this Mac (the system's, then the person's): what Settings
    /// offers to install. The app has no sandbox (no entitlements), so it reads them directly.
    nonisolated static func adobeFolders() -> [URL] {
        let fm = FileManager.default
        let roots = [URL(fileURLWithPath: "/Library/Application Support/Adobe/CameraRaw/LensProfiles", isDirectory: true),
                     URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Adobe/CameraRaw/LensProfiles",
                                                                             isDirectory: true)]
        return roots.filter { root in
            guard let all = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return false }
            for case let url as URL in all where url.pathExtension.lowercased() == "lcp" { return true }
            return false
        }
    }

    enum Source: String, Sendable, CaseIterable { case adobeInstalled = "adobe-installed", user = "user" }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case sqlite(String), newerSchema(Int), unreadable(String)
        var description: String {
            switch self {
            case .sqlite(let s): "SQLite: \(s)"
            case .newerSchema(let n): "the lens database was written by a newer SpektraLab (schema \(n))"
            case .unreadable(let s): s
            }
        }
    }

    /// A lens as the popup lists it: one row a lens, by its maker and pretty name.
    struct Lens: Hashable, Sendable, Identifiable, Codable {
        /// `maker/name`: what a frame's choice is kept by (a row id changes with a reinstall; this does not).
        var key: String
        var maker: String
        var name: String
        /// False where every profile of it is a fisheye's (read, not applied: the app's model is rectilinear).
        var rectilinear: Bool
        var id: String { key }
        static func key(maker: String, name: String) -> String { maker + "/" + name }
    }

    struct Skip: Sendable, Equatable { var name: String; var reason: String }

    struct Progress: Sendable, Equatable { var done: Int; var total: Int; var skipped: Int }

    struct Report: Sendable, Equatable {
        var added = 0, replaced = 0, unchanged = 0
        var skipped: [Skip] = []
        var cancelled = false
    }

    struct Counts: Sendable, Equatable { var files = 0, lenses = 0, variants = 0, entries = 0 }

    /// What a decode is handed for a database lens (`LensResolver`): the profile made for one frame, and the word its
    /// kept pictures are keyed by.
    struct Resolved: Sendable, Equatable {
        var lens: Lens
        /// The body the chosen profile was measured on, and whether it is a RAW profile.
        var camera: String
        var raw: Bool
        /// The source file's SHA-256 (hex).
        var hash: String
        var profile: LensProfile
        /// `file.1:<name>@<first 16 of the hash>`: a replaced profile re-develops; another lens is another word.
        var word: String {
            let safe = String(lens.name.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
            return LensProfile.Source.file.rawValue + ":" + safe + "@" + hash.prefix(16)
        }
    }

    /// A frame's facts, as its EXIF gives them: what `recommended` and `profile` match and interpolate by.
    struct Frame: Sendable, Equatable {
        var make = "", model = "", lens = ""
        var lensID: String?
        var focal: Double?
        var focal35: Double?
        var fNumber: Double?
        var focusDistance: Double?
        /// The picture's size (either orientation; the sensor's is taken as landscape).
        var width: Double?, height: Double?
        var isRAW = true

        /// The file's facts from ImageIO (no RAW filter is opened).
        static func read(_ url: URL, isRAW: Bool = true) -> Frame {
            var f = Frame(isRAW: isRAW)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return f }
            let tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            let exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            let aux = p[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]
            func str(_ d: [String: Any], _ k: CFString) -> String { ((d[k as String] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            func num(_ d: [String: Any], _ k: CFString) -> Double? { (d[k as String] as? NSNumber)?.doubleValue }
            f.make = str(tiff, kCGImagePropertyTIFFMake)
            f.model = str(tiff, kCGImagePropertyTIFFModel)
            f.lens = str(exif, kCGImagePropertyExifLensModel)
            if f.lens.isEmpty { f.lens = str(aux, kCGImagePropertyExifAuxLensModel) }
            f.lensID = (aux[kCGImagePropertyExifAuxLensID as String]).map { "\($0)" }
            f.focal = num(exif, kCGImagePropertyExifFocalLength)
            f.focal35 = num(exif, kCGImagePropertyExifFocalLenIn35mmFilm)
            f.fNumber = num(exif, kCGImagePropertyExifFNumber)
            f.focusDistance = num(exif, kCGImagePropertyExifSubjectDistance).flatMap { $0 > 0 ? $0 : nil }
            f.width = num(p, kCGImagePropertyPixelWidth)
            f.height = num(p, kCGImagePropertyPixelHeight)
            return f
        }

        /// The profile's target: landscape pixels, the sensor as a crop where the EXIF says, APEX aperture.
        var target: LCP.Target {
            var t = LCP.Target()
            if let w = width, let h = height, w > 0, h > 0 { t.width = max(w, h); t.height = min(w, h) }
            if let f = focal, let f35 = focal35, f > 0, f35 > 0, (0.1...10).contains(f35 / f) { t.sensorFactor = f35 / f }
            t.focal = focal.flatMap { $0 > 0 ? $0 : nil }
            t.distance = focusDistance
            t.aperture = fNumber.flatMap { $0 > 0 ? 2 * log2($0) : nil }
            return t
        }
    }

    nonisolated let url: URL
    private var db: OpaquePointer?
    private var refusal: Failure?
    private var index: [IndexedLens]?

    init(url: URL) { self.url = url }
    deinit { if let db { sqlite3_close_v2(db) } }

    // MARK: the file

    private func database() throws -> OpaquePointer {
        if let db { return db }
        if let refusal { throw refusal }
        do {
            let opened = try openFile()
            db = opened
            return opened
        } catch let error as Failure {
            refusal = error
            throw error
        }
    }

    private func openFile() throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(handle)
            throw Failure.sqlite(message)
        }
        do {
            sqlite3_busy_timeout(handle, 2000)
            try Self.exec(handle, "PRAGMA journal_mode = WAL")
            try Self.exec(handle, "PRAGMA synchronous = NORMAL")
            try Self.exec(handle, "PRAGMA foreign_keys = ON")
            let found = Self.userVersion(handle)
            if found > Self.schema { throw Failure.newerSchema(Int(found)) }
            if found < Self.schema {
                try Self.exec(handle, """
                    BEGIN IMMEDIATE;
                    CREATE TABLE IF NOT EXISTS lcp_file(
                        id INTEGER PRIMARY KEY, source TEXT NOT NULL, name TEXT NOT NULL, hash TEXT NOT NULL,
                        UNIQUE(source, name));
                    CREATE TABLE IF NOT EXISTS lens(
                        id INTEGER PRIMARY KEY, maker TEXT NOT NULL, name TEXT NOT NULL, UNIQUE(maker, name));
                    CREATE TABLE IF NOT EXISTS variant(
                        id INTEGER PRIMARY KEY, lens INTEGER NOT NULL REFERENCES lens(id) ON DELETE CASCADE,
                        file INTEGER NOT NULL REFERENCES lcp_file(id) ON DELETE CASCADE,
                        camera TEXT NOT NULL, make TEXT NOT NULL, model TEXT NOT NULL, raw INTEGER NOT NULL,
                        sensor REAL, rectilinear INTEGER NOT NULL);
                    CREATE INDEX IF NOT EXISTS variant_lens ON variant(lens);
                    CREATE INDEX IF NOT EXISTS variant_file ON variant(file);
                    CREATE TABLE IF NOT EXISTS entry(
                        variant INTEGER NOT NULL REFERENCES variant(id) ON DELETE CASCADE,
                        focal REAL, distance REAL, aperture REAL, params TEXT NOT NULL);
                    CREATE INDEX IF NOT EXISTS entry_variant ON entry(variant);
                    CREATE TABLE IF NOT EXISTS alias(
                        key TEXT NOT NULL, lens INTEGER NOT NULL REFERENCES lens(id) ON DELETE CASCADE,
                        PRIMARY KEY(key, lens)) WITHOUT ROWID;
                    CREATE INDEX IF NOT EXISTS alias_lens ON alias(lens);
                    PRAGMA user_version = \(Self.schema);
                    COMMIT;
                    """)
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
            throw Failure.sqlite(message)
        }
    }

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

    private struct Statement {
        let handle: OpaquePointer
        let db: OpaquePointer
        enum Value { case int(Int), double(Double), text(String), null }

        init(_ db: OpaquePointer, _ sql: String, _ values: [Value] = []) throws {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw Failure.sqlite(String(cString: sqlite3_errmsg(db)))
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
                case .null: sqlite3_bind_null(stmt, at)
                }
            }
        }

        func rows(_ each: (OpaquePointer) throws -> Void) throws {
            defer { sqlite3_finalize(handle) }
            while true {
                let rc = sqlite3_step(handle)
                if rc == SQLITE_DONE { return }
                guard rc == SQLITE_ROW else { throw Failure.sqlite(String(cString: sqlite3_errmsg(db))) }
                try each(handle)
            }
        }
        func run() throws { try rows { _ in } }
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }
    private static func double(_ stmt: OpaquePointer, _ column: Int32) -> Double? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, column)
    }

    // MARK: installing

    /// A file read off the actor: its name, hash and variants, or why it was skipped.
    private struct Parsed: Sendable {
        var name: String
        var hash: String
        var maker: String?
        var result: Result<[LCP.Variant], LCP.ReadError>
    }

    /// Every `.lcp` under `folder` (Camera Raw's `LensProfiles`, its `1.0`, or any folder of them), as
    /// `adobe-installed`. Cancellable between batches (what is written stays: a second install takes up where it
    /// stopped); `progress` is called after each batch, off the main actor.
    func install(folder: URL, progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Report {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath()
        let files = (FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension.lowercased() == "lcp" }
            .sorted { $0.path < $1.path }
        let jobs = files.map { file -> (URL, String, String?) in
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path
            let rel = path.hasPrefix(base.path + "/") ? String(path.dropFirst(base.path.count + 1)) : file.lastPathComponent
            return (file, rel, Self.folderMaker(relative: rel, folder: base))
        }
        return try await ingest(jobs, source: .adobeInstalled, progress: progress)
    }

    /// One `.lcp` the person chose, as `user`, listed under its pretty name's maker.
    func add(file: URL) async throws -> Report {
        try await ingest([(file, file.lastPathComponent, nil)], source: .user, progress: { _ in })
    }

    private func ingest(_ jobs: [(URL, String, String?)], source: Source, progress: @escaping @Sendable (Progress) -> Void) async throws -> Report {
        let db = try database()
        var kept: [String: String] = [:]
        try Statement(db, "SELECT name, hash FROM lcp_file WHERE source = ?", [.text(source.rawValue)]).rows {
            kept[Self.text($0, 0)] = Self.text($0, 1)
        }
        var report = Report()
        let batch = 64
        var done = 0
        for start in stride(from: 0, to: jobs.count, by: batch) {
            if Task.isCancelled { report.cancelled = true; break }
            let slice = Array(jobs[start..<min(start + batch, jobs.count)])
            let keptHere = kept
            let parsed: [Parsed] = await withTaskGroup(of: Parsed?.self) { group in
                for (url, name, maker) in slice {
                    group.addTask { Self.parse(url, name: name, maker: maker, unless: keptHere[name]) }
                }
                var out: [Parsed] = []
                for await p in group { if let p { out.append(p) } }
                return out.sorted { $0.name < $1.name }
            }
            report.unchanged += slice.count - parsed.count
            try transaction { db in
                for p in parsed {
                    switch p.result {
                    case .failure(let e): report.skipped.append(Skip(name: p.name, reason: e.description))
                    case .success(let variants):
                        let replacing = kept[p.name] != nil
                        // One savepoint a file: a file that cannot be written is skipped whole, the batch goes on.
                        try Self.exec(db, "SAVEPOINT file")
                        do {
                            try write(db, p, variants, source: source)
                            try Self.exec(db, "RELEASE file")
                        } catch is EncodingError {
                            try Self.exec(db, "ROLLBACK TO file; RELEASE file")
                            report.skipped.append(Skip(name: p.name, reason: LCP.ReadError.unkeepable.description))
                            continue
                        }
                        kept[p.name] = p.hash
                        if replacing { report.replaced += 1 } else { report.added += 1 }
                    }
                }
                try Statement(db, "DELETE FROM lens WHERE id NOT IN (SELECT lens FROM variant)").run()
            }
            index = nil
            done += slice.count
            progress(Progress(done: done, total: jobs.count, skipped: report.skipped.count))
        }
        return report
    }

    /// Read and hash a file; nil where its hash is `unless` (kept already).
    private nonisolated static func parse(_ url: URL, name: String, maker: String?, unless kept: String?) -> Parsed? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return Parsed(name: name, hash: "", maker: maker, result: .failure(.unreadable("cannot read the file")))
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if hash == kept { return nil }
        do { return Parsed(name: name, hash: hash, maker: maker, result: .success(try LCP.read(data))) }
        catch let e as LCP.ReadError { return Parsed(name: name, hash: hash, maker: maker, result: .failure(e)) }
        catch { return Parsed(name: name, hash: hash, maker: maker, result: .failure(.malformed("\(error)"))) }
    }

    private func write(_ db: OpaquePointer, _ p: Parsed, _ variants: [LCP.Variant], source: Source) throws {
        try Statement(db, "DELETE FROM lcp_file WHERE source = ? AND name = ?", [.text(source.rawValue), .text(p.name)]).run()
        try Statement(db, "INSERT INTO lcp_file(source, name, hash) VALUES(?, ?, ?)", [.text(source.rawValue), .text(p.name), .text(p.hash)]).run()
        let file = Int(sqlite3_last_insert_rowid(db))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var makers = Set<String>()
        try Statement(db, "SELECT DISTINCT maker FROM lens").rows { makers.insert(Self.text($0, 0)) }
        for v in variants {
            let c = v.camera
            let name = c.lensPretty.isEmpty ? (c.lens.isEmpty ? c.profileName : c.lens) : c.lensPretty
            guard !name.isEmpty else { continue }
            let maker = p.maker ?? Self.prettyMaker(name: name, make: c.make, known: makers)
            try Statement(db, "INSERT OR IGNORE INTO lens(maker, name) VALUES(?, ?)", [.text(maker), .text(name)]).run()
            var lens = 0
            try Statement(db, "SELECT id FROM lens WHERE maker = ? AND name = ?", [.text(maker), .text(name)]).rows {
                lens = Int(sqlite3_column_int64($0, 0))
            }
            let rectilinear = v.entries.contains { !$0.fisheye && $0.geometry != nil }
            // Encoded before anything is written, so a value JSON cannot hold fails the file, not half of it.
            let camera = String(decoding: try encoder.encode(c), as: UTF8.self)
            let params = try v.entries.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            try Statement(db, "INSERT INTO variant(lens, file, camera, make, model, raw, sensor, rectilinear) VALUES(?, ?, ?, ?, ?, ?, ?, ?)",
                          [.int(lens), .int(file), .text(camera), .text(c.make), .text(c.model.isEmpty ? c.cameraPretty : c.model),
                           .int(c.raw ? 1 : 0), c.sensorFactor.map { .double($0) } ?? .null, .int(rectilinear ? 1 : 0)]).run()
            let variant = Int(sqlite3_last_insert_rowid(db))
            for (e, json) in zip(v.entries, params) {
                try Statement(db, "INSERT INTO entry(variant, focal, distance, aperture, params) VALUES(?, ?, ?, ?, ?)",
                              [.int(variant), e.focal.map { .double($0) } ?? .null, e.distance.map { .double($0) } ?? .null,
                               e.aperture.map { .double($0) } ?? .null, .text(json)]).run()
            }
            for alias in Set(([name, c.lens] + c.alternateLensNames).map(Self.matchKey)) where !alias.isEmpty {
                try Statement(db, "INSERT OR IGNORE INTO alias(key, lens) VALUES(?, ?)", [.text(alias), .int(lens)]).run()
            }
        }
    }

    /// Everything of `source` gone (a lens of both sources keeps its other's variants).
    func removeAll(source: Source) throws {
        try transaction { db in
            try Statement(db, "DELETE FROM lcp_file WHERE source = ?", [.text(source.rawValue)]).run()
            try Statement(db, "DELETE FROM lens WHERE id NOT IN (SELECT lens FROM variant)").run()
        }
        index = nil
    }

    // MARK: makers

    /// Makers whose name a pretty name may start with (Adobe's folder names; the database's own are added).
    static let knownMakers = ["Apple", "Canon", "Cosina", "DJI", "Fujifilm", "Google", "Hasselblad", "Irix", "Laowa", "Leica", "Lensbaby",
                              "Mamiya", "Minolta", "Nikon", "Olympus", "OM", "Panasonic", "Pentax", "Ricoh", "Rokinon", "Samsung",
                              "Samyang", "Schneider", "Sigma", "Sony", "Tamron", "Tokina", "TTArtisan", "Viltrox", "Voigtlander",
                              "Yongnuo", "Zeiss"]

    /// The maker by the install folder: the first folder under a version folder ("1.0") or under the folder chosen;
    /// nil for a file directly in it, or under `ThirdParty` (the pretty name's maker then).
    nonisolated static func folderMaker(relative: String, folder: URL) -> String? {
        var parts = relative.split(separator: "/").map(String.init)
        parts.removeLast()
        while let first = parts.first, first.allSatisfy({ $0.isNumber || $0 == "." }) || first == "LensProfiles" { parts.removeFirst() }
        if let first = parts.first { return first == "ThirdParty" ? nil : first }
        let own = folder.lastPathComponent
        return own.allSatisfy({ $0.isNumber || $0 == "." }) || own == "LensProfiles" || own == "ThirdParty" ? nil : own
    }

    /// The maker by name: the pretty name's first word where it is a maker's (as that maker is spelled), else the
    /// camera make's first word, capitalised.
    nonisolated static func prettyMaker(name: String, make: String, known: Set<String> = []) -> String {
        let all = Set(knownMakers).union(known)
        func word(_ s: String) -> String { String(s.split(whereSeparator: { $0 == " " || $0 == "," }).first ?? "") }
        let first = word(name).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if let m = all.first(where: { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == first }) { return m }
        let m = word(make).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if let k = all.first(where: { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == m }) { return k }
        return m.isEmpty ? "Other" : m.prefix(1).uppercased() + m.dropFirst()
    }

    // MARK: names

    /// A name as it is matched (see the head): "Canon RF 45mm F1.2 STM" and "RF45mm F1.2 STM" are both "rf45f1.2stm".
    nonisolated static func matchKey(_ name: String) -> String {
        var t = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        t = t.replacingOccurrences(of: "f/", with: "f").replacingOccurrences(of: "ƒ", with: "f")
        t = t.replacingOccurrences(of: #"(\d)\s*mm\b"#, with: "$1", options: .regularExpression)
        var words = t.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }).map(String.init)
        if words.count > 1, makerWords.contains(words[0]) { words.removeFirst() }
        return words.joined()
    }
    nonisolated static let makerWords: Set<String> = Set(knownMakers.map { $0.lowercased() } + ["fuji"])

    /// A name's focal range and f-number ("Canon RF 28-70mm F2 L USM": 28…70, 2), for the near matches.
    nonisolated static func optics(_ name: String) -> (lo: Double, hi: Double, f: Double?)? {
        let s = name.replacingOccurrences(of: ",", with: ".")
        guard let r = s.range(of: #"(\d+(?:\.\d+)?)(?:\s*-\s*(\d+(?:\.\d+)?))?\s*mm"#, options: .regularExpression) else { return nil }
        let nums = s[r].split(whereSeparator: { !($0.isNumber || $0 == ".") }).compactMap { Double($0) }
        guard let lo = nums.first else { return nil }
        let rest = s[r.upperBound...]
        var f: Double?
        if let fr = rest.range(of: #"[fF]\s*/?\s*(\d+(?:\.\d+)?)"#, options: .regularExpression) {
            f = Double(rest[fr].drop(while: { !$0.isNumber }))
        } else if let fr = rest.range(of: #"1:(\d+(?:\.\d+)?)"#, options: .regularExpression) {
            f = Double(rest[fr].dropFirst(2))
        }
        return (lo, nums.count > 1 ? nums[1] : lo, f)
    }

    nonisolated static func makeKey(_ make: String) -> String {
        String(make.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).first ?? "")
    }

    // MARK: lists

    func counts(source: Source? = nil) throws -> Counts {
        let db = try database()
        var c = Counts()
        let w = source.map { "WHERE f.source = '\($0.rawValue)'" } ?? ""
        try Statement(db, "SELECT COUNT(*) FROM lcp_file f \(w)").rows { c.files = Int(sqlite3_column_int64($0, 0)) }
        try Statement(db, "SELECT COUNT(DISTINCT v.lens), COUNT(*) FROM variant v JOIN lcp_file f ON f.id = v.file \(w)").rows {
            c.lenses = Int(sqlite3_column_int64($0, 0)); c.variants = Int(sqlite3_column_int64($0, 1))
        }
        try Statement(db, "SELECT COUNT(*) FROM entry e JOIN variant v ON v.id = e.variant JOIN lcp_file f ON f.id = v.file \(w)").rows {
            c.entries = Int(sqlite3_column_int64($0, 0))
        }
        return c
    }

    /// Every maker with a lens, by name.
    func makers() throws -> [String] {
        Array(Set(try indexed().map(\.lens.maker))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A maker's lenses, by pretty name: one row a lens.
    func lenses(maker: String) throws -> [Lens] {
        try indexed().filter { $0.lens.maker == maker }.map(\.lens)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func lens(key: String) throws -> Lens? { try indexed().first { $0.lens.key == key }?.lens }

    /// How a recommended lens was found.
    enum Match: Int, Comparable, Sendable {
        /// A focal range and f-number like the frame's lens, another name: offered, never taken for it.
        case similar = 1
        /// The frame's lens name, normalised, is one of the lens's names.
        case name = 3
        /// The frame's EXIF lens string is the one Adobe recorded for the lens.
        case exif = 4
        static func < (a: Match, b: Match) -> Bool { a.rawValue < b.rawValue }
    }

    struct Recommendation: Sendable, Equatable { var lens: Lens; var match: Match }

    /// What the popup's "recommended" rows are for `frame`, best first: the lens whose recorded EXIF name is the
    /// frame's (`exif`), then whose name is the frame's normalised (`name`), then lenses of the same focal range and
    /// f-number with the frame's focal length inside it (`similar`, the camera's maker's first, at most `limit` in
    /// all).
    func recommended(for frame: Frame, limit: Int = 8) throws -> [Recommendation] {
        let all = try indexed()
        let lensName = frame.lens.trimmingCharacters(in: .whitespaces)
        let key = Self.matchKey(lensName)
        let make = Self.makeKey(frame.make)
        let optics = Self.optics(lensName)
        var scored: [(Recommendation, Double)] = []
        for l in all where l.lens.rectilinear {
            var m: Match, s: Double
            if !lensName.isEmpty, l.exifNames.contains(lensName.lowercased()) { m = .exif; s = 4 }
            else if !key.isEmpty, l.aliases.contains(key) { m = .name; s = 3 }
            else if let o = optics, let lo = l.optics, abs(o.lo - lo.lo) < 0.6, abs(o.hi - lo.hi) < 0.6,
                    let fo = o.f, let fl = lo.f, abs(fo - fl) < 0.06 {
                m = .similar; s = 1 + Self.overlap(key, l.aliases)
            } else { continue }
            if let id = frame.lensID, !id.isEmpty, l.lensIDs.contains(id) { s += 0.2 }
            if l.makes.contains(make) { s += 0.3 }
            if let f = frame.focal, let o = l.optics, f < o.lo - 0.6 || f > o.hi + 0.6, m == .similar { continue }
            scored.append((Recommendation(lens: l.lens, match: m), s))
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lens.name < $1.0.lens.name }.prefix(limit).map(\.0)
    }

    /// Share of the shorter name's characters in a common run (a cheap similarity for ranking near matches).
    private static func overlap(_ a: String, _ names: Set<String>) -> Double {
        names.map { b -> Double in
            let x = Array(a), y = Array(b)
            guard !x.isEmpty, !y.isEmpty else { return 0 }
            var best = 0, row = [Int](repeating: 0, count: y.count + 1)
            for i in 1...x.count {
                var prev = 0
                for j in 1...y.count {
                    let tmp = row[j]
                    row[j] = x[i - 1] == y[j - 1] ? prev + 1 : 0
                    best = max(best, row[j]); prev = tmp
                }
            }
            return Double(best) / Double(min(x.count, y.count))
        }.max() ?? 0
    }

    // MARK: a frame's profile

    /// `lens`'s profile for `frame`: the best variant (a RAW profile for a RAW, a JPEG's for a JPEG; then the same
    /// camera model, else the same make, else the nearest sensor format factor), interpolated to the frame's focal
    /// length, focus distance and aperture (`LCP.profile`). Nil: no such lens, or nothing rectilinear in it.
    func profile(lens key: String, for frame: Frame, terms: LCP.Terms = LCP.Terms()) throws -> Resolved? {
        let db = try database()
        guard let l = try indexed().first(where: { $0.lens.key == key }) else { return nil }
        return try Self.profile(db, lensID: l.id, lens: l.lens, for: frame, terms: terms)
    }

    /// `profile(lens:for:terms:)` read through a connection of its own, opened read-only and closed again: for a decode
    /// that resolves a chosen lens where no actor can be waited on (`LensResolver`, a few milliseconds, once a frame and
    /// a session). Nil where the file is not there or has no such lens; never creates the file.
    nonisolated static func profileNow(file: URL, lens key: String, for frame: Frame, terms: LCP.Terms = LCP.Terms()) -> Resolved? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close_v2(handle)
            return nil
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 2000)
        guard userVersion(db) == schema, let slash = key.firstIndex(of: "/") else { return nil }
        let maker = String(key[..<slash]), name = String(key[key.index(after: slash)...])
        var id: Int?
        try? Statement(db, "SELECT id FROM lens WHERE maker = ? AND name = ?", [.text(maker), .text(name)]).rows {
            id = Int(sqlite3_column_int64($0, 0))
        }
        guard let id else { return nil }
        return try? profile(db, lensID: id, lens: Lens(key: key, maker: maker, name: name, rectilinear: true), for: frame, terms: terms)
    }

    private nonisolated static func profile(_ db: OpaquePointer, lensID: Int, lens: Lens, for frame: Frame, terms: LCP.Terms) throws -> Resolved? {
        let l = (id: lensID, lens: lens)
        struct Row { var id: Int; var camera: LCP.Camera; var hash: String; var rectilinear: Bool }
        var rows: [Row] = []
        let decoder = JSONDecoder()
        try Statement(db, "SELECT v.id, v.camera, f.hash, v.rectilinear FROM variant v JOIN lcp_file f ON f.id = v.file WHERE v.lens = ? ORDER BY v.id",
                      [.int(l.id)]).rows {
            guard let c = try? decoder.decode(LCP.Camera.self, from: Data(Self.text($0, 1).utf8)) else { return }
            rows.append(Row(id: Int(sqlite3_column_int64($0, 0)), camera: c, hash: Self.text($0, 2), rectilinear: sqlite3_column_int($0, 3) != 0))
        }
        let target = frame.target
        let model = Self.matchKey(frame.model), make = Self.makeKey(frame.make)
        func rank(_ r: Row) -> Double {
            var s = 0.0
            if r.camera.raw == frame.isRAW { s += 8 }
            let models = [r.camera.model, r.camera.uniqueModel, r.camera.cameraPretty].map(Self.matchKey).filter { !$0.isEmpty }
            if !model.isEmpty, models.contains(model) { s += 4 }
            if !make.isEmpty, Self.makeKey(r.camera.make) == make { s += 2 }
            if let a = target.sensorFactor, let b = r.camera.sensorFactor, a > 0, b > 0 { s -= min(abs(log(a / b)), 1.9) }
            return s
        }
        // Best first; a variant without the terms asked of it (Adobe's L-mount Sigma profiles carry light falloff and
        // no distortion: "PreferMetadataDistort") gives way to the next that has them.
        var made: (Row, LensProfile)?
        for row in rows.filter(\.rectilinear).sorted(by: { rank($0) > rank($1) }) {
            var entries: [LCP.Entry] = []
            try Statement(db, "SELECT params FROM entry WHERE variant = ?", [.int(row.id)]).rows {
                if let e = try? decoder.decode(LCP.Entry.self, from: Data(Self.text($0, 0).utf8)) { entries.append(e) }
            }
            guard let p = LCP.profile(LCP.Variant(camera: row.camera, entries: entries), target: target, terms: terms) else { continue }
            let whole = (!terms.distortion || p.distortion != nil) && (!terms.vignetting || p.vignetting != nil)
            if made == nil || whole { made = (row, p) }
            if whole { break }
        }
        guard let (best, profile) = made else { return nil }
        return Resolved(lens: l.lens, camera: best.camera.cameraPretty.isEmpty ? best.camera.model : best.camera.cameraPretty,
                        raw: best.camera.raw, hash: best.hash, profile: profile)
    }

    // MARK: the index

    /// A lens and what it is matched by, held in memory after the first query (a few thousand rows) and dropped on
    /// every write.
    private struct IndexedLens {
        var id: Int
        var lens: Lens
        var aliases: Set<String> = []
        var exifNames: Set<String> = []
        var lensIDs: Set<String> = []
        var makes: Set<String> = []
        var optics: (lo: Double, hi: Double, f: Double?)?
    }

    private func indexed() throws -> [IndexedLens] {
        if let index { return index }
        let db = try database()
        var byID: [Int: IndexedLens] = [:]
        try Statement(db, "SELECT id, maker, name FROM lens").rows {
            let id = Int(sqlite3_column_int64($0, 0)), maker = Self.text($0, 1), name = Self.text($0, 2)
            byID[id] = IndexedLens(id: id, lens: Lens(key: Lens.key(maker: maker, name: name), maker: maker, name: name, rectilinear: false),
                                   optics: Self.optics(name))
        }
        try Statement(db, "SELECT key, lens FROM alias").rows { byID[Int(sqlite3_column_int64($0, 1))]?.aliases.insert(Self.text($0, 0)) }
        let decoder = JSONDecoder()
        try Statement(db, "SELECT lens, camera, rectilinear FROM variant").rows {
            let id = Int(sqlite3_column_int64($0, 0))
            guard byID[id] != nil, let c = try? decoder.decode(LCP.Camera.self, from: Data(Self.text($0, 1).utf8)) else { return }
            if sqlite3_column_int($0, 2) != 0 { byID[id]!.lens.rectilinear = true }
            if !c.lens.isEmpty { byID[id]!.exifNames.insert(c.lens.lowercased()) }
            byID[id]!.exifNames.formUnion(c.alternateLensNames.map { $0.lowercased() })
            if !c.lensID.isEmpty { byID[id]!.lensIDs.insert(c.lensID) }
            byID[id]!.lensIDs.formUnion(c.alternateLensIDs)
            byID[id]!.makes.insert(Self.makeKey(c.make))
        }
        let list = byID.values.sorted { $0.id < $1.id }
        index = list
        return list
    }
}
