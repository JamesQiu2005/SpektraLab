//  MemoryLog.swift — the app's memory as it runs, in the log.
//
//  `cat` `memory` (the owner, 2026-10-12: "a moderately more detailed log
//  system including the ram usage from testers"). Three kinds of
//  record, each with the app's footprint, what is left of its allowance, and
//  the host's own pages, beside what the app was doing:
//
//  | the question | the record |
//  |---|---|
//  | How much did the app hold at each turn of a session? | `mark`, with `at`: `launch`, `active`, `background`, `page` (another page or sheet is on top), `camera` (it started, runs, or stopped), `shot`, `landed` |
//  | Where did it grow, and how near the end did it come? | `rise`, `fall`, `low` (`MemoryTrace`), four readings a second while the app is in front |
//  | What was the session's most, and during what? | `session`, as the app is left |
//
//  **What the app was doing** is `page` (the router's top: "library", "shoot",
//  "develop", a sheet's or a cover's slot), `camera` (the scheduler's own
//  word for it: "camera 48 MP, 1 in flight", or "camera off"), `job` (the job
//  running: "export full 48.8 MP") and `since_shot_s` (seconds since the last
//  shot landed, for ten minutes after it) — the last because of the first
//  day's table (e): whether the camera's memory is still in the app's
//  footprint when a shot's first develop opens it is not known, and this is
//  the record that can say.
//
//  The readings are made off the main thread, so a page that is busy does not
//  stop them; what the app was doing is told from the main thread whenever it
//  changes. A reading is `task_info` and `os_proc_available_memory()`; the
//  host's pages are read only for a record that is written.
//
//  **Not in it**: what the engine holds (`spk_memory_report` hands back a
//  string the engine keeps, and a render's own watch reads it: a second
//  reader would race it). A job's record has the pool as the job saw it.

import Foundation
import UIKit

final class MemoryLog: @unchecked Sendable {
    /// What the app is doing, as the main thread last said it.
    struct Doing: Equatable, Sendable {
        var page = "library"
        var camera = "camera off"
        var job: String?
        var shotLanded: Date?

        var text: String { [page, camera, job].compactMap { $0 }.joined(separator: "; ") }
    }

    /// Seconds between two readings.
    static let every = 0.25

    private let lock = NSLock()
    private var trace = MemoryTrace()
    private var doing = Doing()
    private let queue = DispatchQueue(label: "com.spektralab.mac.memory", qos: .utility)
    private var timer: DispatchSourceTimer?
    @MainActor private var watch: Timer?
    @MainActor private var observers: [NSObjectProtocol] = []

    /// The readings begin; `doing` is asked for once a second on the main
    /// thread, and a page or a camera that has changed leaves a mark.
    @MainActor func begin(doing read: @escaping @MainActor () -> (page: String, camera: String)) {
        guard watch == nil else { return }
        mark("launch")
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ run: @escaping @MainActor () -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { run() }
            })
        }
        on(UIApplication.didBecomeActiveNotification) { [weak self] in
            self?.mark("active")
            self?.resume()
        }
        on(UIApplication.didEnterBackgroundNotification) { [weak self] in
            self?.suspend()
            self?.mark("background")
            self?.session()
        }
        watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let now = read()
                self?.tell(page: now.page, camera: now.camera)
            }
        }
        watch?.tolerance = 0.2
        resume()
    }

    private func resume() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + Self.every, repeating: Self.every, leeway: .milliseconds(50))
            t.setEventHandler { [weak self] in self?.read() }
            t.resume()
            timer = t
        }
    }

    private func suspend() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: what the app is doing

    /// The page on top and the frontend's word for the camera: a mark where
    /// either is another than it was.
    func tell(page: String, camera: String) {
        let (pageChanged, cameraChanged) = lock.withLock {
            let changed = (doing.page != page, doing.camera != camera)
            doing.page = page
            doing.camera = camera
            return changed
        }
        if pageChanged { mark("page") }
        if cameraChanged { mark("camera") }
    }

    /// The job that runs, or none.
    func tell(job: String?) { lock.withLock { doing.job = job } }

    /// The shutter went.
    func shot() { mark("shot") }

    /// A shot's file is in the library.
    func landed() {
        lock.withLock { doing.shotLanded = Date() }
        mark("landed")
    }

    /// Seconds since the last shot landed, for ten minutes after it.
    var sinceShot: Double? {
        lock.withLock { doing.shotLanded }.map { Date().timeIntervalSince($0) }.flatMap { $0 < 600 ? ($0 * 10).rounded() / 10 : nil }
    }

    // MARK: the records

    /// A reading at a moment the app names.
    func mark(_ at: String) {
        let reading = MemoryProbe.read()
        let doing = lock.withLock {
            trace.wrote(footprint: reading.footprint)
            return self.doing
        }
        var fields = Self.fields(reading, doing)
        fields["at"] = at
        Log.note(.memory, "mark", fields)
    }

    /// One of the four readings a second: written where `MemoryTrace` says so.
    private func read() {
        let footprint = MemoryProbe.footprint(), left = MemoryProbe.appAvailable()
        let (notes, doing) = lock.withLock { (trace.take(footprint: footprint, left: left, during: self.doing.text), self.doing) }
        for note in notes {
            var fields = Self.fields(MemoryProbe.read(), doing)
            if case .low(let floor) = note { fields["under_mb"] = floor }
            Log.note(.memory, note.name, fields, level: note.name == "low" ? .warn : .info)
        }
    }

    /// The session's most, as the app is left.
    private func session() {
        let t = lock.withLock { trace }
        guard t.readings > 0 else { return }
        Log.note(.memory, "session", [
            "peak_mb": Int(t.peak >> 20), "peak_during": t.peakDuring,
            "least_allowance_mb": Int(t.least >> 20), "least_during": t.leastDuring, "readings": t.readings,
        ])
    }

    /// What every record of memory carries. Whole megabytes: a log is read by eye.
    static func fields(_ r: MemoryReading, _ doing: Doing) -> [String: Any] {
        var fields: [String: Any] = [
            "footprint_mb": Int(r.footprint >> 20), "allowance_mb": Int(r.appAvailable >> 20),
            "phone_mb": Int(r.phoneHeadroom >> 20), "wired_mb": Int(r.wired >> 20), "compressed_mb": Int(r.compressed >> 20),
            "page": doing.page, "camera": doing.camera,
        ]
        fields["job"] = doing.job
        if let landed = doing.shotLanded, case let s = Date().timeIntervalSince(landed), s < 600 { fields["since_shot_s"] = (s * 10).rounded() / 10 }
        return fields
    }
}

extension Log {
    /// The session's memory log, where a log is kept at all (`AppServices`).
    nonisolated(unsafe) static var memory: MemoryLog?
}
