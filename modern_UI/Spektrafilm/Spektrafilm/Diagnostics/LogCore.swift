//  LogCore.swift — one record, two sinks, and the rules that keep it cheap.
//
//  RFC-016 §2: a ring buffer in memory that is always on, and a file per app
//  session, newline-delimited JSON. Everything here obeys §5.1 — **nothing on
//  a render path waits on I/O**: a record is appended to the ring under a lock
//  (an array store), handed to the file sink on that sink's own serial queue,
//  and the caller returns without having touched a descriptor.
//
//  §5.3 is why the message is an `@autoclosure`. `Session`'s canvas call sites
//  build strings like "applyRender uploaded 2560x1707" on a path that runs
//  sixty times a second, and the `debug` record they now produce must cost
//  nothing at the level most users run at — the string is never built unless a
//  sink will take it.
//
//  The five fields every record carries are the RFC's: `t`, `lvl`, `cat`,
//  `msg`, then whatever the category adds. A human with `grep`, a script and a
//  test are the consumers; a log viewer is not.

import Foundation
import os

// MARK: - levels

/// Severity, most severe first: `error < warn < info < debug < trace`.
///
/// The comparison is by `rawValue`, so a level *passes* a threshold when it is
/// `<=` it — `.debug <= .debug` and `.error <= .info` both hold, which is the
/// direction every check in this file reads in.
enum LogLevel: Int, CaseIterable, Comparable, Sendable {
    case error = 0, warn, info, debug, trace

    var name: String {
        switch self {
        case .error: "error"
        case .warn: "warn"
        case .info: "info"
        case .debug: "debug"
        case .trace: "trace"
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// What `os_log` is told (§11.2). `info` goes out as `.default` so
    /// Console.app persists it and a running app can be watched live from
    /// outside; `debug`/`trace` go out as `.debug`, which `log stream
    /// --level debug` sees and the archive does not keep.
    var osLogType: OSLogType {
        switch self {
        case .error: .error
        case .warn, .info: .default
        case .debug, .trace: .debug
        }
    }

    /// A record at this level goes to the ring when the ring's floor accepts
    /// it. `<=` rather than `<`: the floor is inclusive.
    func reaches(_ floor: LogLevel) -> Bool { rawValue <= floor.rawValue }
}

/// The Settings page's three positions (RFC-016 §6), and the wire the rest of
/// the app reads them through.
enum LogLevelSetting: String, CaseIterable, Identifiable, Sendable {
    case normal, detailed, verbose

    var id: String { rawValue }

    var level: LogLevel {
        switch self {
        case .normal: .info
        case .detailed: .debug
        case .verbose: .trace
        }
    }

    var label: String {
        switch self {
        case .normal: "Normal"
        case .detailed: "Detailed"
        case .verbose: "Verbose"
        }
    }

    /// The one sentence each position needs under it. Detailed and Verbose
    /// revert to Normal on the next launch (§6), and the caption says so —
    /// a user who turns one on to capture something must not be left
    /// wondering whether it stayed on.
    var detail: String {
        switch self {
        case .normal: "The everyday record: opens, renders, exports, memory and errors."
        case .detailed: "Adds what the canvas and the engine do per step. Resets to Normal on the next launch."
        case .verbose: "Everything, including per-node traces. Costs render speed, and resets to Normal on the next launch."
        }
    }
}

// MARK: - categories

/// The eight the RFC names, and no more (§1's closing rule: a record nobody has
/// asked a question about does not exist — growing this list means adding a
/// question to §1's table first).
enum LogCategory: String, CaseIterable, Sendable {
    /// launch, the settings that affect rendering, a clean exit.
    case app
    /// the capabilities block, `warm_up`, `open`, `set_params`.
    case engine
    /// one record per frame open, carrying the LoadClock stages.
    case open
    /// one per render: tier, pixels, elapsed, reprint or full.
    case render
    /// one per export, with the applied EV so it can be reconciled with the
    /// canvas that was approved.
    case export
    /// `phys_footprint` at boundaries, plus the session peak.
    case memory
    /// what `canvasLog` prints today, at `debug`.
    case canvas
    /// the raw engine text beside the user-facing message.
    case error
}

// MARK: - values and fields

/// A field's value. Small on purpose: §5.4 — no pixels, ever.
enum LogValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    var json: String {
        switch self {
        case .string(let s): LogRecord.quote(s)
        case .int(let i): String(i)
        case .double(let d): LogRecord.number(d)
        case .bool(let b): b ? "true" : "false"
        }
    }
}

/// One `key: value` pair after `msg`. A struct rather than a tuple so it is
/// `Sendable` without ceremony and the call sites read as what they are.
struct LogField: Sendable, Equatable {
    let name: String
    let value: LogValue

    init(_ name: String, _ value: LogValue) { self.name = name; self.value = value }
    init(_ name: String, _ value: String) { self.init(name, .string(value)) }
    init(_ name: String, _ value: Int) { self.init(name, .int(value)) }
    init(_ name: String, _ value: Double) { self.init(name, .double(value)) }
    init(_ name: String, _ value: Bool) { self.init(name, .bool(value)) }
}

// MARK: - the record

struct LogRecord: Sendable {
    let time: Date
    let level: LogLevel
    let category: LogCategory
    let message: String
    let fields: [LogField]

    /// One JSONL line, without the newline.
    func jsonLine() -> String {
        var out = #"{"t":"# + LogRecord.quote(LogTime.isoString(time))
        out += #","lvl":"# + LogRecord.quote(level.name)
        out += #","cat":"# + LogRecord.quote(category.rawValue)
        out += #","msg":"# + LogRecord.quote(message)
        for f in fields { out += "," + LogRecord.quote(f.name) + ":" + f.value.json }
        return out + "}"
    }

    /// A record's value for a field, if it carries one.
    func value(_ name: String) -> LogValue? { fields.first { $0.name == name }?.value }

    /// The field as a number, whichever way it was written.
    ///
    /// `px` is written as an `Int` and `ms` as a `Double`, and a reader that
    /// has to know which is a reader that breaks the day a field changes kind.
    /// The typed `value(_:)` above stays for the cases that care.
    func number(_ name: String) -> Double? {
        switch value(name) {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }

    func text(_ name: String) -> String? {
        if case .string(let s)? = value(name) { return s }
        return nil
    }

    func flag(_ name: String) -> Bool? {
        if case .bool(let b)? = value(name) { return b }
        return nil
    }

    // MARK: json primitives

    /// A JSON string literal. Escapes what JSON requires and nothing else —
    /// control characters go out as `\u00xx` rather than raw, so a stray one
    /// cannot break the line-oriented contract the file is read under.
    static func quote(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 { out += String(format: "\\u%04x", c.value) }
                else { out.unicodeScalars.append(c) }
            }
        }
        return out + "\""
    }

    /// A JSON number. Whole numbers print as whole numbers (a millisecond
    /// count of `8` should not read `8.000`), and a value that rounds to zero
    /// at three decimals falls back to `%g` rather than lying with `0`.
    /// Non-finite values become `null`: JSON has no spelling for them, and a
    /// NaN that reaches the file must not make the file unparseable.
    static func number(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int(d)) }
        var s = String(format: "%.3f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        if s == "0" || s == "-0" { s = String(format: "%g", d) }
        return s
    }
}

/// The timestamp format, and the file-name format, in one place.
enum LogTime {
    /// `2026-09-12T11:04:21.114+08:00` — the RFC's example, with the offset of
    /// the machine that wrote it.
    ///
    /// Behind a lock rather than declared `nonisolated(unsafe)`: these are
    /// reached from the main actor, from the engine actor and from the file
    /// queue, an uncontended `NSLock` is ~20 ns, and formatting a timestamp
    /// happens once per record that a sink actually takes. Correctness that
    /// costs nothing is not worth a claim about a formatter's internals.
    private static let isoFormatter = Guarded<ISO8601DateFormatter>({
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }())

    static func isoString(_ date: Date) -> String {
        isoFormatter.withLock { $0.string(from: date) }
    }

    /// `2026-09-12T11-04-21` — ISO 8601 with the colons taken out, because a
    /// colon in a filename reads as a path separator in Finder and in half the
    /// shell commands a user will point at these files.
    private static let fileStampFormatter = Guarded<DateFormatter>({
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f
    }())

    static func fileStamp(_ date: Date) -> String {
        fileStampFormatter.withLock { $0.string(from: date) }
    }
}

// MARK: - the ring buffer

/// A fixed-capacity ring, oldest record dropped on overflow. The RFC's ~2000
/// records exist so that when something goes wrong the last few seconds are
/// *already* recorded — the alternative is "turn logging on and reproduce it",
/// which is the thing this exists to delete.
struct LogRing: Sendable {
    private var storage: [LogRecord?]
    private var head = 0      // next slot to write
    private var filled = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        storage = Array(repeating: nil, count: capacity)
    }

    var capacity: Int { storage.count }
    var count: Int { filled }

    mutating func append(_ record: LogRecord) {
        storage[head] = record
        head = (head + 1) % storage.count
        if filled < storage.count { filled += 1 }
    }

    /// Oldest first.
    func snapshot() -> [LogRecord] {
        guard filled == storage.count else {
            return storage[0..<filled].compactMap { $0 }
        }
        return (storage[head...] + storage[..<head]).compactMap { $0 }
    }

    mutating func removeAll() {
        for i in storage.indices { storage[i] = nil }
        head = 0
        filled = 0
    }
}

// MARK: - sinks

/// A destination for a formatted line. `append` must not block: the file sink
/// hops to its own queue, and the `os_log` sink writes to a memory buffer the
/// system drains.
protocol LogSink: AnyObject, Sendable {
    func append(_ line: String, record: LogRecord)
    func flush()
}

/// `os_log` as the second sink (§11.2). Every field is marked `public`,
/// which the user accepted for the price it is: any process on the machine can
/// read these records. No field carries image data, and the file sink remains
/// the complete record — this one is a *live view* (Console.app, `log stream`)
/// not the archive.
final class OSLogSink: LogSink, @unchecked Sendable {
    private let subsystem: String

    init(subsystem: String) { self.subsystem = subsystem }

    func append(_ line: String, record: LogRecord) {
        let logger = Logger(subsystem: subsystem, category: record.category.rawValue)
        // One interpolated, fully-public line rather than a field-per-argument
        // call: the sinks then say exactly the same thing, and a field added
        // to a record cannot silently be redacted out of this half.
        logger.log(level: record.level.osLogType, "\(line, privacy: .public)")
    }

    func flush() {}
}

// MARK: - the log

/// The process's log. One per app session (RFC-016 §2), and one `shared`
/// instance for the app: `Session`, `EngineClient` and `Exporter` all reach for
/// it, from the main actor, from an actor of their own and from detached work.
///
/// **It is inert until a session is started.** No session, no sinks: records
/// go to the ring and nowhere else. That is what keeps a unit test that builds
/// a `Session` from writing into the user's `~/Library/Logs`, and it is why the
/// app's launch record is written by `Diagnostics.start()` rather than by this
/// type's initialisation.
final class Log: @unchecked Sendable {
    static let shared = Log()
    static let defaultRingCapacity = 2000

    private struct State {
        var level: LogLevel = .info
        var ring: LogRing
        var sinks: [LogSink] = []
        var fileSink: LogFileSink?
        /// Test- and support-facing: "logging off" is a state the cost check
        /// (§8) measures against, and it is also what a user with a full disk
        /// would want. It silences the file and `os_log`; the ring stays on.
        var sinksEnabled = true
        var directory: URL?
        var sessionFile: URL?
        var startedAt: Date?
    }

    private let state = Guarded(State(ring: LogRing(capacity: Log.defaultRingCapacity)))
    /// What the launch's scan of the previous session found (§1.7), kept for
    /// whoever asks later — the Settings page and the diagnostic bundle both
    /// do, and both ask after the scan has finished.
    private let previousSessionBox = Guarded<PreviousSessionReport?>(nil)
    /// Test seam: the launch record's timestamp, so a file name and its
    /// records can be asserted against each other.
    private let clock: @Sendable () -> Date

    init(ringCapacity: Int = Log.defaultRingCapacity, clock: @escaping @Sendable () -> Date = { Date() }) {
        state.value.ring = LogRing(capacity: ringCapacity)
        self.clock = clock
    }

    // MARK: configuration

    var level: LogLevel {
        get { state.value.level }
        set { state.value.level = newValue }
    }

    /// What the ring takes. The floor is `debug` at Normal and Detailed and
    /// `trace` at Verbose, so a user who asked for everything gets everything
    /// — including in the ring, which is the half a diagnostic bundle can
    /// still recover after a crash.
    var ringFloor: LogLevel {
        let level = state.value.level
        return level == .trace ? .trace : .debug
    }

    var sinksEnabled: Bool {
        get { state.value.sinksEnabled }
        set { state.value.sinksEnabled = newValue }
    }

    var sessionFile: URL? { state.value.sessionFile }
    var directory: URL? { state.value.directory }
    var sessionStartedAt: Date? { state.value.startedAt }
    /// The previous session's file and how it ended, or nil when this launch
    /// found no previous session at all. Nil **before** the scan has run is
    /// indistinguishable from nil after, so `startSession`'s
    /// `onPreviousSession` is the way to know it finished.
    var previousSessionReport: PreviousSessionReport? { previousSessionBox.value }
    /// The file sink's own failure (a read-only directory, a full disk), for
    /// the Settings page to show rather than the app pretending (§4).
    var fileError: String? { state.value.fileSink?.failure.value }

    @discardableResult
    func setFileSinkEnabled(_ on: Bool) -> Bool {
        let had = state.value.sinksEnabled
        state.value.sinksEnabled = on
        return had
    }

    // MARK: writing

    /// The whole write path. Message and fields are closures so that a record
    /// no sink will take is never built (§5.3).
    func log(_ level: LogLevel, _ category: LogCategory,
             _ message: @autoclosure () -> String,
             _ fields: @autoclosure () -> [LogField] = []) {
        let (threshold, floor, sinks, enabled) = state.withLock {
            ($0.level, $0.level == .trace ? LogLevel.trace : LogLevel.debug, $0.sinks, $0.sinksEnabled)
        }
        let toRing = level.reaches(floor)
        let toSinks = enabled && !sinks.isEmpty && level.reaches(threshold)
        guard toRing || toSinks else { return }

        let record = LogRecord(time: clock(), level: level, category: category,
                               message: message(), fields: fields())
        if toRing { state.withLock { $0.ring.append(record) } }
        guard toSinks else { return }
        let line = record.jsonLine()
        for sink in sinks { sink.append(line, record: record) }
        // §5.1: an error record is flushed at once, so a failure that takes
        // the process with it is already on disk when it happens.
        if level == .error { for sink in sinks { sink.flush() } }
    }

    func error(_ category: LogCategory, _ message: @autoclosure () -> String,
               _ fields: @autoclosure () -> [LogField] = []) {
        log(.error, category, message(), fields())
    }
    func warn(_ category: LogCategory, _ message: @autoclosure () -> String,
              _ fields: @autoclosure () -> [LogField] = []) {
        log(.warn, category, message(), fields())
    }
    func info(_ category: LogCategory, _ message: @autoclosure () -> String,
              _ fields: @autoclosure () -> [LogField] = []) {
        log(.info, category, message(), fields())
    }
    func debug(_ category: LogCategory, _ message: @autoclosure () -> String,
               _ fields: @autoclosure () -> [LogField] = []) {
        log(.debug, category, message(), fields())
    }
    func trace(_ category: LogCategory, _ message: @autoclosure () -> String,
               _ fields: @autoclosure () -> [LogField] = []) {
        log(.trace, category, message(), fields())
    }

    // MARK: reading (tests, the diagnostic bundle, the ring after a failure)

    func records() -> [LogRecord] { state.value.ring.snapshot() }
    func records(category: LogCategory) -> [LogRecord] { records().filter { $0.category == category } }
    var recordCount: Int { state.value.ring.count }

    // MARK: the session

    /// Start a session: clean up, then open `filmify-<stamp>-<pid>.jsonl` in
    /// `directory` with `latest.jsonl` beside it.
    ///
    /// Cleaning is enqueued on the file sink's own queue **before** anything
    /// can be written, which is what §4 asks for — it runs at launch, off the
    /// main thread, before the session's own file exists. Returns the file the
    /// session will be written to, so the settings page can reveal it before
    /// the first record has landed.
    @discardableResult
    func startSession(destination: URL, retention: LogRetention, level: LogLevel,
                      subsystem: String = "com.hanze.filmify",
                      previousSessionCheck: Bool = true,
                      onPreviousSession: (@Sendable (PreviousSessionReport?) -> Void)? = nil) -> URL {
        endSession()   // a second start in one process replaces the first
        previousSessionBox.value = nil
        let now = clock()
        let file = destination.appending(path: "filmify-\(LogTime.fileStamp(now))-\(ProcessInfo.processInfo.processIdentifier).jsonl")
        let sink = LogFileSink(directory: destination, sessionFile: file, retention: retention)
        state.withLock {
            $0.level = level
            $0.directory = destination
            $0.sessionFile = file
            $0.startedAt = now
            $0.fileSink = sink
            $0.sinks = [sink, OSLogSink(subsystem: subsystem)]
        }
        sink.prepare(previousSession: { [weak self] report in
            self?.previousSessionBox.value = report
            // §1.7: the *absence* of a session-end record is how a hang, a
            // jetsam kill or a panic shows up on the next launch.
            //
            // `self` and not a global: the finding belongs to the log whose
            // session was checked, and a test that gave a session its own log
            // must not have to guess which log its records went to. (It wrote
            // to `Log.shared` for one iteration, and the only thing that
            // noticed was a test — which is the right thing to have noticed.)
            if previousSessionCheck, let report, !report.endedCleanly {
                self?.warn(.app, "the previous session ended without a clean exit", [
                    .init("previous", report.file),
                    .init("age_s", report.ageSeconds),
                    .init("marker", "unclean_exit"),
                ])
            }
            onPreviousSession?(report)
        })
        return file
    }

    /// Flush, close, and record nothing: the exit record is the caller's
    /// (`Diagnostics.finish()`), because it carries what the app knows.
    func endSession() {
        let sink = state.value.fileSink
        sink?.close()
        state.withLock {
            $0.sinks = []
            $0.fileSink = nil
            $0.sessionFile = nil
            $0.directory = nil
            $0.startedAt = nil
        }
    }

    /// Everything written so far is on disk when this returns. Used by tests,
    /// by the diagnostic bundle, and by session end.
    func flushNow() { state.value.fileSink?.flushNow() }

    /// Clean the destination by hand — "Clear logs now" (§4): everything
    /// except the file this session is writing.
    func clearLogs(completion: (@Sendable (LogCleanupOutcome) -> Void)? = nil) {
        guard let sink = state.value.fileSink else { return }
        sink.perform { outcome in completion?(outcome) }
    }

    /// Drop the ring. Tests only; the app's session is long-lived on purpose.
    func resetRing() { state.withLock { $0.ring.removeAll() } }
}

/// A lock around one value. The log has four or five pieces of mutable state
/// read from three different isolation domains, and one small box per concern
/// is clearer than a single lock held over all of them.
final class Guarded<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) { storage = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&storage)
    }
}
