//  JobLog.swift — the evidence of a job's own making, written beside its output.
//
//  RFC-016 §11.4: "A batch export also writes a job log **into the export
//  destination**, next to the files it produced, so a folder of exports carries
//  the record of how it was made: which recipe, which engine build, per-frame
//  timings, per-frame applied EV, and anything that failed."
//
//  The batch half of that is RFC-017 and does not exist yet. The single export
//  does, and it is the same file: one export's job log is the batch's job log
//  with one frame in it. The shape is the session log's — the same five fields,
//  the same categories — so a reader who can read one can read the other, and
//  a batch can append to this rather than invent a second format.
//
//  It is written **at the end of the job, in one write**. That is the opposite
//  of the session log's batching and it is right for the same reason the
//  session log batches: this file is not on a render path, it is the artifact,
//  and a half-written job log beside a finished TIFF would be worse than none.

import Foundation

struct JobLog {
    private(set) var records: [LogRecord] = []
    private let clock: @Sendable () -> Date

    init(clock: @escaping @Sendable () -> Date = { Date() }) { self.clock = clock }

    mutating func note(_ level: LogLevel, _ message: String, _ fields: [LogField] = []) {
        records.append(LogRecord(time: clock(), level: level, category: .export,
                                 message: message, fields: fields))
    }

    /// The job's line-oriented text, oldest first.
    func text() -> String {
        records.map { $0.jsonLine() }.joined(separator: "\n") + (records.isEmpty ? "" : "\n")
    }

    /// `<output without extension>.joblog.jsonl`, beside what it describes.
    static func url(beside output: URL) -> URL {
        output.deletingPathExtension().appendingPathExtension("joblog.jsonl")
    }

    @discardableResult
    func write(beside output: URL) throws -> URL {
        let url = JobLog.url(beside: output)
        try text().write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
