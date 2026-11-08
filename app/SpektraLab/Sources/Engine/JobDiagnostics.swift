//  JobDiagnostics.swift — every job the scheduler ran, kept where a Mac can read it.
//
//  RFC-036 R8 has the scheduler make a record of every job: its plan and its
//  budget beside what the engine measured of itself — the decode, the open
//  and the render, the footprint's peak, what the host had left. The bench
//  writes them to a file (`JobLogFile`); until 2026-10-07 the app did not, so
//  the owner's first use of the engine build on the host left no time and no
//  memory to read back. A debug build over the engine now keeps them in
//  `Documents/scheduler-log.jsonl`, one JSON object a line, beside the camera's
//  and the library's reports:
//
//      xcrun devicectl device copy from --device <udid> --domain-type appDataContainer \
//        --domain-identifier <bundle id> --source Documents/scheduler-log.jsonl --destination <file>
//
//  It is the copy that is still there when the operating system has ended the app.

import Foundation

enum JobDiagnostics {
    #if DEBUG
    /// One file across launches; begun again once it is past this.
    private static let most = 4 << 20
    @MainActor private static var file: JobLogFile?

    @MainActor static func keep(_ scheduler: RenderQueue) {
        let documents = ImportService.root      // not the user's ~/Documents on a Mac
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let url = documents.appendingPathComponent("scheduler-log.jsonl")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let log = JobLogFile(url: url, fresh: size > most)
        file = log
        scheduler.onRecord = { log.append($0) }
    }
    #else
    @MainActor static func keep(_ scheduler: RenderQueue) {}
    #endif
}
