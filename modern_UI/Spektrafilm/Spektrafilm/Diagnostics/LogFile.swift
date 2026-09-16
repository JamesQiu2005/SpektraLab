//  LogFile.swift — the file sink, and the half that keeps it from becoming a
//  disk leak.
//
//  RFC-016 §4: keep 7 days, 100 MB and 20 files, by mtime, oldest first.
//  Cleaning runs at launch on the background queue **before** the session's
//  own file is opened, and never during a render.
//
//  Two rules shape everything here:
//
//  - **Nothing on a render path waits on I/O** (§5.1). `append` hops to a
//    serial queue and returns; the queue holds a small batch and writes it
//    when the batch fills, when a second has passed, or when something asks.
//    `fsync` is never called — not per record, not per batch.
//  - **A log the app cannot delete is a support problem** (§4), so cleaning
//    fails *quietly* and reports: the failure lands in `failure`, the Settings
//    page shows it, and the app does not pretend the directory is fine.

import Foundation

/// The three numbers the user sets, and the defaults the RFC proposes.
struct LogRetention: Sendable, Equatable {
    var days: Int = 7
    var maxBytes: Int = 100_000_000
    var maxFiles: Int = 20

    static let `default` = LogRetention()
}

/// What cleaning did, or why it could not.
struct LogCleanupOutcome: Sendable, Equatable {
    var deleted: [String] = []
    var failure: String?
    var keptFiles = 0
    var keptBytes = 0

    var summary: String {
        if let failure { return "cleaning failed: \(failure)" }
        return deleted.isEmpty ? "nothing to clean" : "deleted \(deleted.count) file\(deleted.count == 1 ? "" : "s")"
    }
}

/// A previous session's file, and whether it ended with a session-end record.
/// Its **absence** is the finding (§1.7): a hang, a jetsam kill or a panic all
/// look identical to a normal quit from inside the next launch, and the only
/// thing that tells them apart is that the record is not there.
struct PreviousSessionReport: Sendable, Equatable {
    var file: String
    var endedCleanly: Bool
    /// Seconds since the file was last written — how long ago the process
    /// stopped being able to write anything.
    var ageSeconds: Double
}

enum LogCleanup {

    /// Every name this app has written a session file under.
    ///
    /// New files get `sessionPrefix`; the rest are here because **cleanup has
    /// to be able to see what earlier builds wrote**. The log directory is a
    /// persisted setting, so an install that has been through a rename keeps
    /// writing into the folder it was already pointed at — and a retention
    /// rule that only matched the current name would leave every file from
    /// before the rename in place, for ever, while reporting that it had
    /// cleaned. The names are dead weight the moment the last such file is
    /// gone, and harmless until then.
    static let sessionPrefixes = ["spektralab-", "filmify-", "spektrafilm-"]

    /// What `Log.start` names a new session file.
    static let sessionPrefix = sessionPrefixes[0]

    /// The session files in `directory`, newest first. Only files this app
    /// writes are considered: `latest.jsonl` is a symlink and anything else in
    /// the folder belongs to whoever put it there.
    static func logFiles(in directory: URL, fileManager: FileManager = .default) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { name in
                name.hasSuffix(".jsonl") && sessionPrefixes.contains { name.hasPrefix($0) }
            }
            .map { directory.appending(path: $0) }
            .sorted { modificationDate($0, fileManager) > modificationDate($1, fileManager) }
    }

    static func modificationDate(_ url: URL, _ fileManager: FileManager = .default) -> Date {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }

    static func size(_ url: URL, _ fileManager: FileManager = .default) -> Int {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// Apply the three limits, oldest first, never touching `keeping`.
    ///
    /// The order matters: age first (a file that is simply too old is gone
    /// whatever the totals say), then the byte ceiling, then the count — so a
    /// directory that is over on all three ends up inside all three.
    @discardableResult
    static func clean(directory: URL, retention: LogRetention, keeping: URL? = nil,
                      now: Date = Date(), fileManager: FileManager = .default) -> LogCleanupOutcome {
        var outcome = LogCleanupOutcome()
        let cutoff = now.addingTimeInterval(-Double(retention.days) * 86_400)

        // Oldest first: both totals below drop from this end.
        var survivors = logFiles(in: directory, fileManager: fileManager)
            .filter { $0.lastPathComponent != keeping?.lastPathComponent }
            .sorted { modificationDate($0, fileManager) < modificationDate($1, fileManager) }

        /// A deletion that failed leaves its file in place, and it stays a
        /// survivor — the app must not report a directory as clean when it is
        /// not, and it must not delete twice to make the numbers work.
        var undeletable: [URL] = []

        // 1. Age.
        var alive: [URL] = []
        for file in survivors {
            if modificationDate(file, fileManager) < cutoff {
                if !delete(file, &outcome, fileManager) { alive.append(file) }
            } else {
                alive.append(file)
            }
        }
        survivors = alive

        // 2. Total bytes.
        var total = survivors.reduce(0) { $0 + size($1, fileManager) }
        var byteIndex = 0
        while total > retention.maxBytes, byteIndex < survivors.count {
            let file = survivors[byteIndex]
            let bytes = size(file, fileManager)
            if delete(file, &outcome, fileManager) { total -= bytes } else { undeletable.append(file) }
            byteIndex += 1
        }
        survivors = Array(survivors[byteIndex...])

        // 3. File count.
        var countIndex = 0
        while survivors.count + undeletable.count - countIndex > retention.maxFiles,
              countIndex < survivors.count {
            let file = survivors[countIndex]
            if !delete(file, &outcome, fileManager) { undeletable.append(file) }
            countIndex += 1
        }
        survivors = Array(survivors[countIndex...])

        let final = survivors + undeletable
        outcome.keptFiles = final.count
        outcome.keptBytes = final.reduce(0) { $0 + size($1, fileManager) }
        return outcome
    }

    /// "Clear logs now" (§4): everything except the file this session is
    /// writing. The symlink goes with them and is put back by the sink.
    @discardableResult
    static func clear(directory: URL, keeping: URL?, fileManager: FileManager = .default) -> LogCleanupOutcome {
        var outcome = LogCleanupOutcome()
        for file in logFiles(in: directory, fileManager: fileManager)
        where file.lastPathComponent != keeping?.lastPathComponent {
            delete(file, &outcome, fileManager)
        }
        let link = directory.appending(path: "latest.jsonl")
        if FileManager.default.fileExists(atPath: link.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try? fileManager.removeItem(at: link)
        }
        return outcome
    }

    @discardableResult
    private static func delete(_ url: URL, _ outcome: inout LogCleanupOutcome,
                               _ fileManager: FileManager) -> Bool {
        do {
            try fileManager.removeItem(at: url)
            outcome.deleted.append(url.lastPathComponent)
            return true
        } catch {
            // Reported, not thrown: a directory that has been moved or made
            // read-only must not stop the app from logging what it can.
            if outcome.failure == nil { outcome.failure = "\(url.lastPathComponent): \(error.localizedDescription)" }
            return false
        }
    }

    /// The newest session file that is not the one being written now.
    static func lastSession(in directory: URL, excluding current: URL?,
                            fileManager: FileManager = .default) -> PreviousSessionReport? {
        guard let file = logFiles(in: directory, fileManager: fileManager)
            .first(where: { $0.lastPathComponent != current?.lastPathComponent }) else { return nil }
        return PreviousSessionReport(
            file: file.lastPathComponent,
            endedCleanly: tail(file).contains(SessionEndMarker),
            ageSeconds: max(0, Date().timeIntervalSince(modificationDate(file, fileManager))))
    }

    /// A session-end record is a record whose `marker` field says so. Matched
    /// as text rather than parsed: this runs over the tail of a file that may
    /// be 100 MB, and a JSON parse per line to answer one yes/no is not worth
    /// it.
    static let SessionEndMarker = #""marker":"session_end""#

    /// The last 64 KB of a file — everything needed to see whether the last
    /// thing a process wrote was an orderly goodbye. Read through a handle so
    /// that a large file costs one seek and one read.
    static func tail(_ url: URL, bytes: Int = 65_536) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? nil
        return String(decoding: (data ?? Data()).prefix(bytes), as: UTF8.self)
    }
}

// MARK: - the sink

/// The file half: one serial queue, one open descriptor, a small batch.
final class LogFileSink: LogSink, @unchecked Sendable {
    let directory: URL
    let sessionFile: URL
    let retention: LogRetention
    /// The log this sink is one of — weak, because the log holds the sink.
    /// It is how a cleaning failure reaches the *ring* (§4: "it fails quietly,
    /// into the ring buffer"), and it is the owner rather than `Log.shared` so
    /// a test that configured its own log does not have its cleanup failures
    /// land somewhere else.
    weak var owner: Log?

    /// Readable from anywhere; written only on the queue.
    let failure = Guarded<String?>(nil)

    private let queue = DispatchQueue(label: "com.hanze.filmify.log", qos: .utility)
    private var handle: FileHandle?
    private var buffer: [String] = []
    private var timerScheduled = false
    /// Set by `close()`. A record that was already on its way when the session
    /// ended must not reopen the file it just closed — the app is on its way
    /// out, and a log that reappears after "clean exit" is a worse lie than a
    /// line that is lost.
    private var closed = false
    /// Lines held before a write. Big enough that a burst of canvas records is
    /// one `write(2)`, small enough that a crash loses less than a screenful.
    private let batchLines = 64
    /// The longest a record can sit in memory. "The last few seconds are
    /// already recorded" is the ring's promise; this is the file's.
    private let flushInterval: TimeInterval = 1.0

    init(directory: URL, sessionFile: URL, retention: LogRetention) {
        self.directory = directory
        self.sessionFile = sessionFile
        self.retention = retention
    }

    // MARK: the queue's work

    /// Everything that has to happen before the session's own first record:
    /// clean the directory (§4), then look at the previous session (§1.7).
    /// Enqueued before any `append` can be, so the ordering is the queue's
    /// rather than a race.
    func prepare(previousSession: (@Sendable (PreviousSessionReport?) -> Void)?) {
        let directory = self.directory
        let retention = self.retention
        let file = self.sessionFile
        queue.async {
            let outcome = LogCleanup.clean(directory: directory, retention: retention, keeping: file)
            if let why = outcome.failure {
                self.failure.value = why
                self.owner?.warn(.app, "cleaning the log directory failed", [
                    .init("why", why), .init("directory", directory.path),
                ])
            }
            if let previousSession {
                previousSession(LogCleanup.lastSession(in: directory, excluding: file))
            }
        }
    }

    func append(_ line: String, record: LogRecord) {
        queue.async { [self] in
            guard ensureOpen() else { return }
            buffer.append(line)
            if buffer.count >= batchLines {
                flushLocked()
            } else if !timerScheduled {
                timerScheduled = true
                queue.asyncAfter(deadline: .now() + flushInterval) { [self] in flushLocked() }
            }
        }
    }

    func flush() { queue.async { [self] in flushLocked() } }

    /// Blocks until everything queued so far is on disk. Tests, the diagnostic
    /// bundle, and the app on the way out.
    func flushNow() { queue.sync { [self] in flushLocked() } }

    /// Run something on the sink's queue — `clearLogs` uses this so that a
    /// cleanup cannot run in the middle of a batch write.
    func perform(_ body: @escaping @Sendable (LogCleanupOutcome) -> Void) {
        let directory = self.directory
        let file = self.sessionFile
        queue.async {
            let outcome = LogCleanup.clear(directory: directory, keeping: file)
            if let why = outcome.failure { self.failure.value = why }
            body(outcome)
        }
    }

    func close() {
        queue.sync { [self] in
            flushLocked()
            try? handle?.close()
            handle = nil
            closed = true
        }
    }

    // MARK: on the queue

    private func flushLocked() {
        guard !buffer.isEmpty else { timerScheduled = false; return }
        let text = buffer.joined(separator: "\n") + "\n"
        buffer.removeAll(keepingCapacity: true)
        timerScheduled = false
        guard let handle, let data = text.data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // A write that fails is not retried: the file is gone, full or
            // read-only, and the ring still has the records. Saying so once is
            // the whole of what the app can do about it.
            if failure.value == nil { failure.value = "writing \(sessionFile.lastPathComponent): \(error.localizedDescription)" }
        }
    }

    private func ensureOpen() -> Bool {
        if closed { return false }
        if handle != nil { return true }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: sessionFile.path) {
                guard fileManager.createFile(atPath: sessionFile.path, contents: nil) else {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
            let open = try FileHandle(forWritingTo: sessionFile)
            try open.seekToEnd()
            handle = open
            linkLatest(fileManager)
            failure.value = nil
            return true
        } catch {
            if failure.value == nil {
                failure.value = "opening \(sessionFile.lastPathComponent): \(error.localizedDescription)"
            }
            return false
        }
    }

    /// `latest.jsonl` → this session's file. A relative destination, so the
    /// link still resolves if the directory is moved or synced somewhere else.
    private func linkLatest(_ fileManager: FileManager) {
        let link = directory.appending(path: "latest.jsonl")
        try? fileManager.removeItem(at: link)
        try? fileManager.createSymbolicLink(atPath: link.path,
                                            withDestinationPath: sessionFile.lastPathComponent)
    }
}
