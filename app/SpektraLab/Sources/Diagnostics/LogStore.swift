//  LogStore.swift — the app's own log: one file a session, one record a line.
//
//  The desktop's RFC-016, cut to a host. A build other people use has to be
//  able to say what it did on their host without a Mac beside it: which
//  build and which reference device, what each develop and export took against what was
//  planned for it, what the camera offered, what went wrong, and whether the
//  session before this one ended while the app was in use. Until 2026-10-10
//  only a debug build kept any of it (`JobDiagnostics`, the camera's report),
//  in files only a cable reads.
//
//  **The shape is the desktop's** (RFC-016 §2): newline-delimited JSON, the
//  same four fields first on every line — `t` (when), `lvl`, `cat`, `msg` —
//  then whatever that record carries:
//
//      {"t":"2026-10-10T12:47:03.114+08:00","lvl":"info","cat":"export","msg":"saved","mp":12.2,"s":0.94}
//
//  One file a session, `<folder>/<session>.jsonl`, the session named by the
//  second it began (UTC) and eight hex: `20261010T044703Z-1a2b3c4d`. A session
//  whose file reaches `Limits.sessionBytes` goes on in a new file under a new
//  name, which says where it came from and restates the launch's facts, so
//  every file can be read alone and every file fits one upload.
//
//  **The rules** (RFC-016 §5, and one of the host's own):
//
//  - *Nothing waits on the disk.* A record is made into its line where it is
//    noted and handed to a serial queue; the caller never touches a file.
//  - *Every record reaches the file at once* (no batching, no `fsync`): the
//    session most wanted is the one the operating system ended for memory, and a line the
//    kernel has is kept when the process is ended; one waiting in a buffer of
//    ours is not. At a few records a second this costs nothing to see.
//  - *No pixels, no names.* Sizes, times, settings and counts; never image
//    data, and — unlike the desktop, whose log is its user's own — never a
//    file's name or a place: this log leaves the host. Instrumentation gives
//    none, and `LogScrub` takes out of every string what an error's own words
//    may carry: the app's folder, a file's name, a profile's id.
//  - *It keeps itself small* (`Limits`, RFC-016 §4): 7 days, 20 files, 16 MB,
//    cleaned at launch and whenever a file is begun; never the file in use.
//  - *The log never ends the app.* A full disk or a folder gone is a record
//    not written.
//
//  Foundation only, so `tools/log_selftest.swift` checks all of it on a Mac.

import Foundation

enum LogLevel: String, Sendable { case error, warn, info, debug }

/// What a record is about (RFC-016's `cat`, with the host's own).
enum LogCategory: String, Sendable {
    /// The app's own course: launch, in front, left, ended; memory warnings.
    case app
    /// Which engine runs, and what it said of itself.
    case engine
    /// One develop or export as the scheduler ran it: `start`, then `end` with its record.
    case job
    /// One exported file: what was asked, what was written, where it went.
    case export
    /// The library in numbers; an import; an original brought from Photos.
    case library
    /// What a develop page's visit changed.
    case develop
    /// The log's own sending.
    case upload
    /// the operating system's own reports for this app (MetricKit).
    case system
    /// The app's footprint and what the reference device has left, as the app runs (`MemoryLog`).
    case memory
    /// The light table: one record a gesture (what the fingers did, the zoom, the largest jump, the
    /// frame rate meanwhile), never a frame at a time, never a picture or a path.
    case lighttable
}

final class LogStore: @unchecked Sendable {
    struct Limits: Equatable, Sendable {
        /// A file not written for this long goes.
        var days = 7
        var files = 20
        var totalBytes: Int64 = 16 << 20
        /// One file's most, and so one upload's: a mebibyte. The server takes
        /// 4 MiB, but on its plan a request has 10 ms of CPU and an upload of
        /// 4 MiB measured 6.6 to 11.6 of them, one of 1 MiB 1.9 to 4.4
        /// (`LogShipping.swift`, "Limits"); a file it cannot take would
        /// stand in the way of every file after it (`LogShipper.ship` stops
        /// at the first that does not go). It is also what a session sent
        /// again as it grows costs a host on cellular, each time.
        var sessionBytes: Int64 = 1 << 20
        /// One record's most; a longer one is noted by its size alone.
        var lineBytes = 512 << 10
    }

    /// How a session's file ends: what the next launch reads of the one before it.
    struct Ending: Equatable, Sendable {
        var session: String
        /// The app's last word of its own course in that file: `launch`,
        /// `continued`, `active`, `inactive`, `background` or `terminate`.
        /// Empty when the file has none.
        var last: String
        /// When the file's last record was written.
        var at: Date?
        /// Jobs begun and never ended, each as "export full 48.8 MP".
        var open: [String]

        /// The app was in front when the file stopped: it did not leave, it
        /// was ended — a crash, or the operating system taking its memory back.
        var inUse: Bool { ["launch", "continued", "active"].contains(last) }
    }

    let folder: URL
    let limits: Limits
    private let queue = DispatchQueue(label: "com.spektralab.mac.log", qos: .utility)
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> String
    // On the queue.
    private var session: String
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var restated: Data?
    private var before: Ending?

    /// `folder` is made if it is not there. The session before this one is
    /// read and the folder cleaned on the log's own queue, before this
    /// session's first line; nothing here waits for either.
    init(folder: URL, limits: Limits = Limits(), now: @escaping @Sendable () -> Date = { Date() },
         id: @escaping @Sendable () -> String = { String(format: "%08x", UInt32.random(in: 0...UInt32.max)) }) {
        self.folder = folder
        self.limits = limits
        self.now = now
        makeID = id
        session = Self.name(now(), id())
        queue.async { [self] in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A log is not a thing to restore from a backup.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var place = folder
            try? place.setResourceValues(values)
            let last = Self.sessions(in: folder).first
            before = last.flatMap { Self.ending(of: $0) }
            Self.clean(folder, limits: limits, now: now(), keeping: nil)
            open()
            if let before {
                var fields: [String: Any] = ["session": before.session, "last": before.last, "in_use": before.inUse]
                if let at = before.at { fields["idle_s"] = now().timeIntervalSince(at).rounded() }
                if !before.open.isEmpty { fields["open_jobs"] = before.open }
                append(Self.line(at: now(), before.inUse ? .warn : .info, .app, "previous", fields))
            }
        }
    }

    deinit { try? handle?.close() }

    // MARK: writing

    /// One record. The line is made here, on the caller's thread; the file is
    /// the queue's.
    func write(_ level: LogLevel = .info, _ category: LogCategory, _ message: String, _ fields: [String: Any] = [:]) {
        var data = Self.line(at: now(), level, category, message, fields)
        if data.count > limits.lineBytes {
            data = Self.line(at: now(), level, category, message, ["dropped_bytes": data.count])
        }
        queue.async { [self] in append(data) }
    }

    /// What a file this session goes on in says first (`continued`): the
    /// launch's facts, so that file reads alone.
    func restate(_ fields: [String: Any]) {
        let data = Self.line(at: now(), .info, .app, "continued", fields)
        queue.async { [self] in restated = data }
    }

    /// Everything noted so far is in the file when this returns.
    func flush() { queue.sync {} }

    /// The session's name as it stands (it changes when a file fills).
    var current: String { queue.sync { session } }

    /// The session before this one, once it has been read.
    var previous: Ending? { queue.sync { before } }

    private func open() {
        let url = folder.appendingPathComponent(session + ".jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        written = Int64((try? handle?.seekToEnd()) ?? 0)
    }

    private func append(_ data: Data) {
        if written > 0, written + Int64(data.count) > limits.sessionBytes { roll() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
        } catch {
            // The disk is full, or the folder is gone: a record not written.
        }
    }

    /// The file is full: the session goes on in a new one.
    private func roll() {
        let from = session
        try? handle?.close()
        handle = nil
        session = Self.name(now(), makeID())
        Self.clean(folder, limits: limits, now: now(), keeping: nil)
        open()
        written = 0
        var first = Self.line(at: now(), .info, .app, "continued", ["from": from])
        if let restated, let merged = Self.adding(["from": from], to: restated) { first = merged }
        guard let handle else { return }
        try? handle.write(contentsOf: first)
        written = Int64(first.count)
    }

    /// `line` with fields added: the restated launch, with where it came from.
    private static func adding(_ fields: [String: Any], to line: Data) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let t = object.removeValue(forKey: "t") as? String, let date = parse(t),
              let lvl = (object.removeValue(forKey: "lvl") as? String).flatMap(LogLevel.init(rawValue:)),
              let cat = (object.removeValue(forKey: "cat") as? String).flatMap(LogCategory.init(rawValue:)),
              let msg = object.removeValue(forKey: "msg") as? String else { return nil }
        object.merge(fields) { _, new in new }
        return Self.line(at: date, lvl, cat, msg, object)
    }

    // MARK: the folder

    /// "20261010T044703Z-1a2b3c4d": the second the session began, UTC, and eight hex.
    static func name(_ date: Date, _ id: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date) + "-" + id
    }

    /// Whether `name` is a session's (the server takes no other).
    static func isSession(_ name: String) -> Bool {
        name.range(of: "^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$", options: .regularExpression) != nil
    }

    /// The folder's session files, the newest first.
    static func sessions(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" && isSession($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Hold the folder to its limits: by age, by count, by size, the oldest
    /// first, and never the file named `current`. Returns the sessions removed.
    @discardableResult
    static func clean(_ folder: URL, limits: Limits, now: Date, keeping current: String?) -> [String] {
        struct File { var url: URL; var session: String; var bytes: Int64; var written: Date }
        var files: [File] = sessions(in: folder).map { url in
            let a = try? FileManager.default.attributesOfItem(atPath: url.path)
            return File(url: url, session: url.deletingPathExtension().lastPathComponent,
                        bytes: (a?[.size] as? NSNumber)?.int64Value ?? 0, written: (a?[.modificationDate] as? Date) ?? now)
        }
        var gone: [String] = []
        func remove(where leaves: (Int, File) -> Bool) {
            var kept: [File] = []
            for (i, f) in files.enumerated() {
                if f.session != current, leaves(i, f) {
                    try? FileManager.default.removeItem(at: f.url)
                    gone.append(f.session)
                } else {
                    kept.append(f)
                }
            }
            files = kept
        }
        let oldest = now.addingTimeInterval(-Double(limits.days) * 86_400)
        remove { _, f in f.written < oldest }
        remove { i, _ in i >= limits.files }
        // By size: the newest are kept while they fit.
        var total: Int64 = 0
        var fits = Set<String>()
        for f in files {
            total += f.bytes
            if total <= limits.totalBytes || f.session == current || fits.isEmpty { fits.insert(f.session) }
        }
        remove { _, f in !fits.contains(f.session) }
        return gone
    }

    /// How a session's file ends. Nil for a file that cannot be read.
    static func ending(of file: URL) -> Ending? {
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { return nil }
        var last = ""
        var final: Substring?
        var open: [String: String] = [:]
        var order: [String] = []
        // Only the app's and the jobs' lines are read as JSON: a full file is three thousand lines.
        for raw in text.split(separator: "\n") {
            final = raw
            let isApp = raw.contains("\"cat\":\"app\""), isJob = raw.contains("\"cat\":\"job\"")
            guard isApp || isJob,
                  let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
                  let msg = object["msg"] as? String else { continue }
            if isApp, ["launch", "continued", "active", "inactive", "background", "terminate"].contains(msg) { last = msg }
            if isJob, let id = object["id"] as? String {
                if msg == "start" {
                    let mp = (object["mp"] as? NSNumber)?.doubleValue ?? 0
                    open[id] = "\(object["kind"] as? String ?? "?") \(object["tier"] as? String ?? "?") "
                        + String(format: "%.1f MP", mp)
                    order.append(id)
                } else if msg == "end" {
                    open[id] = nil
                }
            }
        }
        // The last line's time, whatever it is of: `{"t":"…"` is how every line begins.
        let at = final.flatMap { line -> Date? in
            guard line.hasPrefix("{\"t\":\"") else { return nil }
            let rest = line.dropFirst(6)
            return rest.firstIndex(of: "\"").flatMap { parse(String(rest[..<$0])) }
        }
        return Ending(session: file.deletingPathExtension().lastPathComponent, last: last, at: at,
                      open: order.compactMap { open[$0] })
    }

    // MARK: a line

    private static let stamper: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    static func stamp(_ date: Date) -> String { stamper.string(from: date) }
    static func parse(_ text: String) -> Date? { stamper.date(from: text) }

    /// A record as its line, the newline with it: the four fields every line
    /// has, then `fields` by name. A field that is nil is left out; a value
    /// JSON has no word for is written as text.
    static func line(at date: Date, _ level: LogLevel, _ category: LogCategory, _ message: String,
                     _ fields: [String: Any]) -> Data {
        var text = "{\"t\":\"" + stamp(date) + "\",\"lvl\":\"" + level.rawValue + "\",\"cat\":\"" + category.rawValue
            + "\",\"msg\":" + LogJSON.string(LogScrub.clean(message))
        for key in fields.keys.sorted() where !["t", "lvl", "cat", "msg"].contains(key) {
            guard let value = fields[key], let written = LogJSON.write(value) else { continue }
            text += "," + LogJSON.string(key) + ":" + written
        }
        text += "}\n"
        return Data(text.utf8)
    }
}

/// JSON, written by hand: one line whatever is given, numbers as short as
/// they read back, and nothing that can raise (`JSONSerialization` does, for a
/// NaN).
enum LogJSON {
    /// `value` as JSON, or nil for a nil. Every string is scrubbed.
    static func write(_ value: Any) -> String? {
        guard let value = unwrapped(value) else { return nil }
        switch value {
        case let text as String: return string(LogScrub.clean(text))
        case let number as NSNumber: return self.number(number)
        case let dictionary as [String: Any]:
            let parts = dictionary.keys.sorted().compactMap { key in write(dictionary[key]!).map { string(key) + ":" + $0 } }
            return "{" + parts.joined(separator: ",") + "}"
        case let array as [Any]: return "[" + array.map { write($0) ?? "null" }.joined(separator: ",") + "]"
        case is NSNull: return nil
        case let date as Date: return string(LogStore.stamp(date))
        case let id as UUID: return string(id.uuidString.lowercased())
        default: return string(LogScrub.clean("\(value)"))
        }
    }

    /// A number: a truth as `true`, a whole number as it is, any other to four
    /// places (a time to a tenth of a millisecond, a megabyte to a hundred bytes).
    static func number(_ n: NSNumber) -> String {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
        switch String(cString: n.objCType) {
        case "d", "f":
            let d = n.doubleValue
            guard d.isFinite else { return string("\(d)") }
            let r = (d * 10_000).rounded() / 10_000
            return r == r.rounded() && abs(r) < 1e15 ? String(Int64(r)) : "\(r)"
        case "Q": return String(n.uint64Value)
        default: return String(n.int64Value)
        }
    }

    static func string(_ text: String) -> String {
        var out = "\""
        out.reserveCapacity(text.utf8.count + 2)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}", "\u{2029}": out += String(format: "\\u%04x", scalar.value)
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    /// An `Any` that holds an optional, opened: nil for a nil.
    private static func unwrapped(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first.flatMap { unwrapped($0.value) }
    }
}

/// What must not be in a line, taken out of a string that may carry it: an
/// error's own words name the file it failed on, and the engine's may name a
/// profile by its id.
enum LogScrub {
    /// Profile ids to the names the app shows (`StockCatalog`): set once, at launch.
    nonisolated(unsafe) static var stockNames: [String: String] = [:]
    /// The app's own folder on this host, which carries nothing but would
    /// make every path a different line on every host.
    nonisolated(unsafe) static var home = NSHomeDirectory()

    private static let kinds = "dng|heic|heif|hif|jpe?g|png|tiff?|arw|cr2|cr3|nef|nrw|raf|rw2|orf|pef|srw|x3f|3fr|iiq|gpr|avif|webp|psd|mov|mp4|xmp"
    /// A path's last part; a name in quotes of each kind (it may hold spaces
    /// and an apostrophe: “Mum’s birthday.JPG”); a bare word that ends as a
    /// picture's file does. Where they cannot tell, they take more, not less.
    private static let patterns: [NSRegularExpression] = [
        "(?<=/)[^/\\n\\r\"“”]+?\\.(\(kinds))(?![A-Za-z0-9])",
        "(?<=“)[^“”\\n\\r/]+?\\.(\(kinds))(?=”)",
        "(?<=\")[^\"\\n\\r/]+?\\.(\(kinds))(?=\")",
        "(?<=‘)[^‘\\n\\r/]+?\\.(\(kinds))(?=’)",
        "(?<=')[^\\n\\r/]+?\\.(\(kinds))(?=')",
        "[^\\s/\"“”‘’'(),;:=<>]+\\.(\(kinds))(?![A-Za-z0-9])",
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func clean(_ text: String) -> String {
        // Most strings are a word or a number's unit: nothing to look for.
        guard text.contains(".") || text.contains("/") || text.contains("_") else { return text }
        var out = text
        if !home.isEmpty {
            out = out.replacingOccurrences(of: "/private" + home, with: "~").replacingOccurrences(of: home, with: "~")
        }
        if out.contains(".") {
            for pattern in patterns {
                out = pattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "<file>.$1")
            }
        }
        if out.contains("_") {
            for (id, name) in stockNames where out.contains(id) { out = out.replacingOccurrences(of: id, with: name) }
        }
        return out
    }
}
