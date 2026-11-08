//  JobLogFile.swift — every job's record, in a file.
//
//  RFC-036 R8: mode, budget, predicted against measured peak and time, waits
//  and their reasons — enough to rebuild any job's schedule. The scheduler
//  keeps the last 200 in memory and sends each to the system log; this is the
//  copy that survives the app being ended, which is the case the records are
//  most wanted for. One JSON object a line, written and flushed as the record
//  is made:
//
//      let log = JobLogFile(url: documents.appendingPathComponent("scheduler-log.jsonl"))
//      scheduler.onRecord = { log.append($0) }

import Foundation

final class JobLogFile {
    let url: URL
    private let handle: FileHandle?
    private let encoder: JSONEncoder

    /// `fresh` starts the file again; otherwise records are added to it.
    init(url: URL, fresh: Bool = true) {
        self.url = url
        if fresh || !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
    }

    deinit { try? handle?.close() }

    func append(_ record: JobRecord) {
        guard let handle, var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        try? handle.write(contentsOf: line)
        try? handle.synchronize()   // a run the host ends still leaves its rows
    }
}
