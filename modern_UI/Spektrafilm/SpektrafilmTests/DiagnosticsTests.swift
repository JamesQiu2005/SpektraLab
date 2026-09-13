//  DiagnosticsTests.swift — RFC-016 §8's six checks, and the machinery around
//  them.
//
//  The repository's rule applies to every one of these: **a check that cannot
//  fail is not a check** (`guards-that-cannot-fire`, AGENTS trap 16), and three
//  checks passed on broken code in the week before this one. So each was seen
//  **red first** — the thing it guards was broken, the test was run, the
//  failure was read, and the file was put back. What was broken for each is in
//  the doc comment of the test itself, so a later reader can re-run the
//  experiment rather than trusting the claim.
//
//  Two of these are integration tests: they open the 1 MP smoke frame and
//  develop it for real, because "a develop emits the expected records" is a
//  claim about the app's own path and a stubbed engine would check the stub.
//  They skip when the frame is not in the checkout, like `OpenPathTests`.

import Metal
import XCTest

@MainActor
final class DiagnosticsTests: XCTestCase {

    // MARK: - the harness

    /// The log this test writes to, and the model that hands it to everything
    /// under test.
    ///
    /// **A log of its own, not `Log.shared`** — and that is the second version
    /// of this harness. The first used the app's shared log, on the argument
    /// that a check should read the log the app actually writes. What that
    /// bought was a suite that failed only when the whole thing ran: another
    /// class's session, still finishing a 45 MP native render in the
    /// background, dropped its render record into the shared log in the middle
    /// of this one's develop — two render records where the develop produced
    /// one, and both of them correct. The injection seam (`Session(diagnostics:)`)
    /// is what makes a test own its records; a global is not an input a test
    /// can set. (AGENTS trap 24, in its `Log.shared` form.)
    private var log: Log!
    private var diagnostics: Diagnostics!

    /// A fresh log directory and a fresh log for one test.
    @discardableResult
    private func configure(session: Bool = true, level: LogLevel = .info) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log = Log(ringCapacity: Log.defaultRingCapacity)
        // The sampler is built on the same log, so the `memory` records this
        // test reads are the ones its own session produced.
        diagnostics = Diagnostics(defaults: try freshDefaults(), log: log)
        let log = log!
        addTeardownBlock {
            log.endSession()
            log.resetRing()
            try? FileManager.default.removeItem(at: dir)
        }
        log.level = level
        log.setFileSinkEnabled(true)
        // The preview resolution is persisted state a *different* test class
        // can leave behind (`Session.previewEdgeKey`), and it decides whether a
        // small frame earns a native render — i.e. whether an assertion about
        // "one render record" sees one or two. A test must own its inputs.
        let previousEdge = UserDefaults.standard.object(forKey: Session.previewEdgeKey) as? Int
        UserDefaults.standard.set(Session.defaultPreviewEdge, forKey: Session.previewEdgeKey)
        addTeardownBlock {
            if let previousEdge {
                UserDefaults.standard.set(previousEdge, forKey: Session.previewEdgeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Session.previewEdgeKey)
            }
        }
        if session {
            log.startSession(destination: dir, retention: .default, level: level,
                                    previousSessionCheck: false)
        }
        return dir
    }

    /// The 1 MP smoke frame the parity harnesses and `OpenPathTests` use, as a
    /// copy: a develop writes a sidecar beside the frame, and the checkout's
    /// copy is shared with every other suite.
    private func smokeFrame() throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // …/SpektrafilmTests
            .deletingLastPathComponent()          // …/Spektrafilm
            .deletingLastPathComponent()          // …/modern_UI
            .deletingLastPathComponent()          // the checkout
            .appending(path: "tests/Test_image/_smoke_1mp.tif")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "the 1 MP smoke frame is not in this checkout")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-diag-frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    /// Develop a frame and return the session that did it.
    private func developedSession() async throws -> (Session, URL) {
        let url = try smokeFrame()
        let session = Session(diagnostics: diagnostics)
        session.open(urls: [url])
        try await waitUntil("the frame to decode", timeout: 90) { session.decoded != nil }
        session.requestPrint()
        try await waitUntil("the print to land", timeout: 120) {
            session.serviceSessionIDForExport != nil && session.frameStates[url] == .processed
                && !session.busy
        }
        log.flushNow()
        return (session, url)
    }

    // MARK: - §8.1 a develop emits the expected records

    /// **Seen red** by deleting `clock.lap("solve")` from `openInService`; the
    /// run failed with "the open record has no solve_ms".
    func testADevelopEmitsTheExpectedRecords() async throws {
        _ = try configure()
        let (session, url) = try await developedSession()
        let records = log.records()

        // One `open` record, and it is the develop's rather than the decode's:
        // the decode-only branch also writes one, which is why the mode is
        // checked rather than counted in the abstract.
        let opens = records.filter { $0.category == .open && $0.text("mode") == "develop" }
        XCTAssertEqual(opens.count, 1, "expected one develop open record, got \(opens.count)")
        let open = try XCTUnwrap(opens.first)
        XCTAssertEqual(open.message, "develop")
        XCTAssertEqual(open.text("frame"), url.lastPathComponent)
        XCTAssertGreaterThan(open.number("px") ?? 0, 0, "the open record has no pixel count")

        // Every stage of the open path, present and non-zero. `decode` and
        // `preview-texture` are in here because the develop continues the open
        // the decode started (see `Session.openClock`) — a develop that
        // reported only its own four laps would be describing half the path.
        for stage in ["decode_ms", "preview_texture_ms", "frame_ms",
                      "engine_open_ms", "solve_ms", "reprint_ms"] {
            guard let ms = open.number(stage) else {
                XCTFail("the open record has no \(stage): \(open.jsonLine())"); continue
            }
            XCTAssertGreaterThan(ms, 0, "\(stage) is not non-zero: \(open.jsonLine())")
        }

        // One render record. The engine writes it (`EngineClient.noteRender`),
        // which is the only place every render passes through; the app's
        // outcome record is a separate `debug` line with a different message.
        let renders = records.filter { $0.category == .render && $0.message == "render" }
        XCTAssertEqual(renders.count, 1,
                       "expected one render record, got \(renders.count): "
                       + renders.map { $0.jsonLine() }.joined(separator: " | "))
        XCTAssertGreaterThan(renders.first?.number("ms") ?? 0, 0)
        XCTAssertGreaterThan(renders.first?.number("px") ?? 0, 0)
        XCTAssertTrue(records.contains { $0.category == .render && $0.message == "outcome"
                                         && $0.text("outcome") == "applied" },
                      "the app never recorded what became of the render")

        // And a memory record at each boundary the RFC names for a develop.
        let reasons = records.filter { $0.category == .memory }.compactMap { $0.text("reason") }
        for reason in ["decode", "engine.open", "first_print"] {
            XCTAssertTrue(reasons.contains(reason), "no memory record for \(reason); got \(reasons)")
        }
        let memory = try XCTUnwrap(records.first { $0.category == .memory })
        XCTAssertGreaterThan(memory.number("mb") ?? 0, 0)
        XCTAssertGreaterThan(memory.number("peak_mb") ?? 0, 0)

        // The same file, parsed: the record is JSONL and a reader can read it.
        // Every record that reaches the *ring* at `info` and above is in the
        // file — the ring holds more, because its floor is `debug` (§2), and
        // that difference is the point of having both.
        log.flushNow()
        let file = try XCTUnwrap(log.sessionFile)
        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n").compactMap { line -> [String: Any]? in
                try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }
        let inBoth = log.records().filter { $0.level.reaches(.info) }.count
        XCTAssertEqual(lines.count, inBoth,
                       "the file and the ring disagree about the info-and-above records")
        XCTAssertTrue(lines.contains { $0["msg"] as? String == "develop" })
        _ = session
    }

    // MARK: - §8.2 logging off costs nothing measurable

    /// **Seen red** by inserting a synchronous write *plus an `fsync`* per
    /// record into `Log.log` — the negative control §8 names. The arm with the
    /// file sink on then took seconds rather than milliseconds and the bound
    /// below failed by more than an order of magnitude; the write was removed
    /// and the test went green again.
    ///
    /// The records are render-shaped and go through the real path, rather than
    /// being N literal reprints: a reprint's *engine* time is three orders of
    /// magnitude larger than the logging it does, so an arm built on reprints
    /// could not fire on a logging regression — which would make it
    /// decoration. What is measured is what the rule is about: the cost the
    /// caller pays for a record.
    func testLoggingOnTheRenderPathCostsNothingMeasurable() throws {
        let dir = try configure()
        let records = 2_000
        let withSink = try timeRecords(records)
        log.flushNow()
        let file = try XCTUnwrap(log.sessionFile)
        let written = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count
        XCTAssertGreaterThanOrEqual(written, records,
                                    "the file sink wrote nothing, so the comparison below proves nothing")

        log.setFileSinkEnabled(false)
        let withoutSink = try timeRecords(records)
        let added = withSink - withoutSink
        let perRecord = added / Double(records) * 1_000_000
        print(String(format: "log cost: %.1f ms with the file sink, %.1f ms with it off, "
                            + "%.1f ms added over %d records (%.1f µs each)",
                     withSink * 1000, withoutSink * 1000, added * 1000, records, perRecord))

        // A bound stated in µs per record, because that is the unit the claim
        // is in: the caller must not wait for a write. 100 µs is ~20× what the
        // real path costs and ~20× under what the synchronous control cost, so
        // it separates them without being a measurement of this machine
        // (AGENTS trap 17: this machine is not a benchmark).
        XCTAssertLessThan(added, Double(records) * 100e-6,
                          String(format: "the file sink added %.1f µs per record", perRecord))
        _ = dir
    }

    private func timeRecords(_ count: Int) throws -> Double {
        let started = Date()
        for i in 0..<count {
            log.info(.render, "render", [
                .init("tier", "live"), .init("kind", "reprint"),
                .init("ms", 12.3), .init("px", 1_707_200), .init("i", i),
            ])
        }
        return Date().timeIntervalSince(started)
    }

    // MARK: - §8.3 rotation actually deletes

    /// **Seen red** by making the age loop unreachable (`if false`); the old
    /// file survived and the assertion below failed naming it.
    func testTheAgeLimitDeletesByModificationDate() throws {
        let dir = try configure(session: false)
        let old = try plant(dir, "filmify-2026-09-01T10-00-00-1.jsonl", bytes: 100, ageDays: 8)
        let recent = try plant(dir, "filmify-2026-09-12T10-00-00-2.jsonl", bytes: 100, ageDays: 1)

        let outcome = LogCleanup.clean(directory: dir, retention: LogRetention(days: 7, maxBytes: 1_000_000, maxFiles: 20))

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "an eight-day-old file survived a seven-day limit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path), "a one-day-old file was deleted")
        XCTAssertEqual(outcome.deleted, [old.lastPathComponent])
        XCTAssertNil(outcome.failure)
    }

    /// **Seen red** by making the byte loop unreachable: the directory stayed
    /// over its ceiling and the assertion failed.
    func testTheByteLimitDeletesOldestFirst() throws {
        let dir = try configure(session: false)
        let files = try (0..<4).map { i in
            try plant(dir, "filmify-2026-09-1\(i)T10-00-00-\(i).jsonl", bytes: 400, ageDays: Double(4 - i))
        }
        let retention = LogRetention(days: 365, maxBytes: 1_000, maxFiles: 100)

        let outcome = LogCleanup.clean(directory: dir, retention: retention)

        // 1600 bytes against a 1000-byte ceiling: the two oldest go, the two
        // newest stay, and what is left fits.
        XCTAssertEqual(outcome.deleted, [files[0].lastPathComponent, files[1].lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[3].path))
        XCTAssertLessThanOrEqual(outcome.keptBytes, retention.maxBytes)
    }

    /// **Seen red** by making the count loop unreachable: 25 files survived a
    /// 20-file limit.
    func testTheFileCountLimitDeletesOldestFirst() throws {
        let dir = try configure(session: false)
        let files = try (0..<25).map { i in
            try plant(dir, String(format: "filmify-2026-09-%02dT10-00-00-%d.jsonl", i + 1, i), bytes: 10,
                      ageDays: Double(25 - i))
        }
        let retention = LogRetention(days: 365, maxBytes: 1_000_000, maxFiles: 20)

        let outcome = LogCleanup.clean(directory: dir, retention: retention)

        XCTAssertEqual(outcome.keptFiles, 20)
        XCTAssertEqual(outcome.deleted.count, 5)
        for file in files.suffix(20) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                          "\(file.lastPathComponent) was deleted although it is among the 20 newest")
        }
        for file in files.prefix(5) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                           "\(file.lastPathComponent) survived although it is among the 5 oldest")
        }
    }

    /// The session's own file is never a candidate, however old or large it is.
    ///
    /// **Seen red** by dropping the `keeping` filter: the file being written
    /// was deleted by its own cleanup.
    func testCleaningNeverDeletesTheFileItIsWritingTo() throws {
        let dir = try configure(session: false)
        let current = try plant(dir, "filmify-2026-09-12T10-00-00-9.jsonl", bytes: 10_000, ageDays: 90)
        let other = try plant(dir, "filmify-2026-09-12T11-00-00-8.jsonl", bytes: 10, ageDays: 1)

        let outcome = LogCleanup.clean(directory: dir,
                                       retention: LogRetention(days: 0, maxBytes: 10, maxFiles: 1),
                                       keeping: current)

        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path),
                      "cleaning deleted the file the session was writing to")
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
        XCTAssertEqual(outcome.deleted, [other.lastPathComponent])
    }

    @discardableResult
    private func plant(_ directory: URL, _ name: String, bytes: Int, ageDays: Double) throws -> URL {
        let url = directory.appending(path: name)
        try Data(repeating: 0x78, count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ageDays * 86_400)], ofItemAtPath: url.path)
        return url
    }

    // MARK: - §8.4 an unclean exit is visible

    /// **Seen red** by making the scan answer "clean" unconditionally — the
    /// mirror of writing the end record unconditionally, and the check has to
    /// be able to tell the two apart or it is not a check.
    func testALogWithNoEndRecordIsReportedAsUnclean() async throws {
        let dir = try configure(session: false)
        let clean = dir.appending(path: "filmify-2026-09-11T10-00-00-1.jsonl")
        let record = LogRecord(time: Date().addingTimeInterval(-90_000), level: .info, category: .app,
                               message: "exit", fields: [.init("marker", "session_end")])
        try (record.jsonLine() + "\n").write(to: clean, atomically: true, encoding: .utf8)
        let unclean = dir.appending(path: "filmify-2026-09-12T10-00-00-2.jsonl")
        let launch = LogRecord(time: Date().addingTimeInterval(-60), level: .info, category: .app,
                               message: "launch", fields: [.init("marker", "launch")])
        try (launch.jsonLine() + "\n").write(to: unclean, atomically: true, encoding: .utf8)

        // The newer one is the one a launch would look at, and it did not end.
        let report = try XCTUnwrap(LogCleanup.lastSession(in: dir, excluding: nil))
        XCTAssertEqual(report.file, unclean.lastPathComponent)
        XCTAssertFalse(report.endedCleanly,
                       "a session that never wrote its end record was reported as clean")
        XCTAssertGreaterThan(report.ageSeconds, 0)

        // And with the clean one newest, the same call says clean — the check
        // has to be able to answer both ways.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3600)],
                                              ofItemAtPath: clean.path)
        let second = try XCTUnwrap(LogCleanup.lastSession(in: dir, excluding: nil))
        XCTAssertEqual(second.file, clean.lastPathComponent)
        XCTAssertTrue(second.endedCleanly)

        // A real launch over that directory writes the finding down (§1.7).
        // The order is put back first — the unclean file newest again — or the
        // launch would be looking at the clean one and the check below would
        // be about nothing.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: unclean.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                                              ofItemAtPath: clean.path)
        log.resetRing()
        log.startSession(destination: dir, retention: .default, level: .info)
        try await waitUntil("the unclean-exit record", timeout: 10) {
            log.records().contains { $0.text("marker") == "unclean_exit" }
        }
        let warn = try XCTUnwrap(log.records().first { $0.text("marker") == "unclean_exit" })
        XCTAssertEqual(warn.level, .warn)
        XCTAssertEqual(warn.category, .app)
    }

    /// The other half of §1.7, and the half that can hide: what `finish()`
    /// writes is what the next launch reads as *clean*.
    ///
    /// The test above plants a marker by hand, and this one does not — which
    /// is the point. If `Diagnostics.finish()` wrote a marker the scanner does
    /// not match (a typo, a rename, a field added to the record), the planted
    /// test would still pass and every real session would be reported unclean
    /// forever. The two halves have to be checked against each other.
    ///
    /// **Seen red** by changing the marker `finish()` writes to `"sessionend"`:
    /// the app's own end record stopped being recognised.
    func testASessionThatFinishesCleanlyReadsAsCleanOnTheNextLaunch() async throws {
        let dir = try configure()
        log.info(.app, "launch", [.init("marker", "launch")])
        let first = try XCTUnwrap(log.sessionFile)

        diagnostics.finish()

        let text = try String(contentsOf: first, encoding: .utf8)
        XCTAssertTrue(text.contains(LogCleanup.SessionEndMarker),
                      "the end record is not the one the next launch looks for: \(text)")
        let report = try XCTUnwrap(LogCleanup.lastSession(in: dir, excluding: nil))
        XCTAssertEqual(report.file, first.lastPathComponent)
        XCTAssertTrue(report.endedCleanly, "the app's own end record was not recognised")

        // …so the launch after it says nothing about an unclean exit.
        log.resetRing()
        log.startSession(destination: dir, retention: .default, level: .info)
        try await Task.sleep(for: .milliseconds(400))
        log.flushNow()
        XCTAssertFalse(log.records().contains { $0.text("marker") == "unclean_exit" },
                       "a session that ended cleanly was reported as an unclean exit")
    }

    // MARK: - §8.5 the memory numbers are the same numbers

    /// **Seen red** by making `Diagnostics.memory` take its own sample instead
    /// of reading the sampler's last one — the page then drifted from the log
    /// and the sample count moved under a read.
    func testTheReadoutAndTheRecordAreTheSameSample() throws {
        let log = Log(ringCapacity: 64)
        let sampler = MemorySampler(log: log, readFootprint: { 1_234_000_000 }, readFree: { 5_000_000_000 })
        let diagnostics = Diagnostics(defaults: try freshDefaults(), log: log, sampler: sampler)

        let sample = sampler.sample("test")
        let records = log.records(category: .memory)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        // The record and the readout cite the same sample: same number, same
        // sequence. That is what makes them unable to disagree.
        XCTAssertEqual(record.number("seq"), Double(sample.seq))
        XCTAssertEqual(record.number("mb"), sample.footprintMB)
        XCTAssertEqual(record.number("peak_mb"), sample.peakMB)
        XCTAssertEqual(record.number("free_mb"), sample.freeMB)

        // Reading the page's readout takes no sample of its own (§8.5), and
        // shows the same numbers.
        let before = sampler.sampleCount
        for _ in 0..<50 { _ = diagnostics.memory }
        XCTAssertEqual(sampler.sampleCount, before, "reading the readout took \(sampler.sampleCount - before) samples")
        XCTAssertEqual(diagnostics.memory?.seq, sample.seq)
        XCTAssertEqual(diagnostics.memory?.footprintBytes, sample.footprintBytes)
        XCTAssertEqual(log.records(category: .memory).count, 1, "a read wrote a record")

        // The peak only ever rises, and it is the peak of the same readings.
        let second = sampler.sample("test2")
        XCTAssertEqual(second.peakBytes, max(sample.footprintBytes, second.footprintBytes))
        XCTAssertEqual(sampler.peak, second.peakBytes)
    }

    private func freshDefaults() throws -> UserDefaults {
        let name = "spk-diag-defaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: - §8.6 no pixels leak

    /// **Seen red** by adding one base64 blob to a render record (a 128-byte
    /// `Data` encoded and attached as a field); the scan found a run of 172
    /// base64 characters and failed.
    func testNoPixelsReachTheRecords() async throws {
        let directory = try configure()
        _ = try await developedSession()
        log.flushNow()

        // The whole file, not just the ring: the serialisation is part of the
        // path a leak would travel.
        let file = try XCTUnwrap(log.sessionFile)
        let text = try String(contentsOf: file, encoding: .utf8)
        if let run = firstBase64Run(in: text, atLeast: 64) {
            XCTFail("a \(run.count)-character base64-looking run is in the log: \(run.prefix(80))…")
        }

        let allowedPrefixes = [NSHomeDirectory(), directory.path, "/var/folders", "/private/var/folders"]
        for record in log.records() {
            for field in record.fields {
                guard case .string(let value) = field.value else { continue }
                XCTAssertLessThanOrEqual(value.count, 512,
                                         "\(record.category)/\(field.name) is \(value.count) characters")
                if field.name == "frame" {
                    XCTAssertFalse(value.contains("/"), "a frame field carries a path: \(value)")
                }
                for path in value.split(separator: " ").filter({ $0.hasPrefix("/") }) {
                    XCTAssertTrue(allowedPrefixes.contains { path.hasPrefix($0) },
                                  "\(record.category)/\(field.name) names \(path), which is not the user's own")
                }
            }
        }
    }

    private func firstBase64Run(in text: String, atLeast: Int) -> String? {
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var run = ""
        for character in text {
            if alphabet.contains(character) {
                run.append(character)
                if run.count >= atLeast { return run }
            } else {
                run = ""
            }
        }
        return nil
    }

    // MARK: - the level, and what it decides (§6)

    /// Detailed and Verbose expire (§6): a user who turns one on to capture
    /// something does not run at `trace` forever.
    ///
    /// **Seen red** by removing the reset in `Diagnostics.init`: the stored
    /// `verbose` came back on the next "launch" (a fresh instance over the same
    /// defaults).
    func testDetailedAndVerboseExpireOnTheNextLaunch() throws {
        let defaults = try freshDefaults()
        let log = Log(ringCapacity: 64)
        defaults.set(LogLevelSetting.verbose.rawValue, forKey: "diag.level")

        let relaunched = Diagnostics(defaults: defaults, log: log,
                                     sampler: MemorySampler(log: log, readFootprint: { 1 }, readFree: { 1 }))
        XCTAssertEqual(relaunched.level, .normal, "a stored Verbose survived the next launch")
        XCTAssertEqual(defaults.string(forKey: "diag.level"), LogLevelSetting.normal.rawValue,
                       "the expiry was not written back, so the next launch would read Verbose again")
        XCTAssertEqual(log.level, .info)
    }

    /// The level decides both sinks: at Normal a `debug` record is in the ring
    /// and not in the file; at Detailed it is in both. And error records always
    /// reach the file, whatever the level (§5.1).
    ///
    /// **Seen red** by gating the file on `ringFloor` instead of the level: the
    /// `debug` record appeared in the file at Normal.
    func testTheLevelDecidesWhatReachesTheFile() async throws {
        let dir = try configure(level: .info)
        log.debug(.canvas, "a canvas trace at Normal")
        log.error(.error, "an error at Normal")
        log.flushNow()
        let file = try XCTUnwrap(log.sessionFile)
        let atNormal = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(atNormal.contains("an error at Normal"))
        XCTAssertFalse(atNormal.contains("a canvas trace at Normal"),
                       "a debug record reached the file at Normal")
        XCTAssertTrue(log.records().contains { $0.message == "a canvas trace at Normal" },
                      "the ring dropped a debug record at Normal — the ring is debug and above, always")

        log.level = .debug
        log.debug(.canvas, "a canvas trace at Detailed")
        log.flushNow()
        let atDetailed = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(atDetailed.contains("a canvas trace at Detailed"),
                      "a debug record did not reach the file at Detailed")
        _ = dir
    }

    // MARK: - the diagnostic bundle (§7)

    /// One button, one zip, and a real tool can read it.
    ///
    /// **Seen red** by passing `includeFileNames: true` while asserting on the
    /// placeholders: the frame name was still in the copied log.
    func testTheBundleIsAZipWithTheLogsAndTheMachineInIt() async throws {
        let dir = try configure()
        log.info(.open, "develop", [.init("frame", "DSC03710.ARW"), .init("px", 24_000_000)])
        log.flushNow()

        let bundle = dir.appending(path: "bundle.zip")
        try DiagnosticBundle.assemble(to: bundle, includeFileNames: false, inputs: .init(
            logDirectory: dir,
            appVersion: "1.2.3", buildNumber: "45",
            engineVersion: "spektrafilm-0.9",
            capabilitiesJSON: #"{"version":"1.2.3"}"#,
            lastError: "This frame is larger than Filmify can render.",
            machine: ["model": "Mac16,7", "gpu": "Apple M4 Max"],
            settings: ["log_level": "normal"],
            previousSession: PreviousSessionReport(file: "filmify-x.jsonl", endedCleanly: false, ageSeconds: 12)))

        // A real unzip, because "it is a zip" is a claim about every tool the
        // user might open it with, not about this test's parser.
        let listing = try run("/usr/bin/unzip", ["-l", bundle.path])
        XCTAssertTrue(listing.contains("logs/"), "the bundle has no logs directory:\n\(listing)")
        XCTAssertTrue(listing.contains("summary.json"))
        XCTAssertTrue(listing.contains("capabilities.json"))
        XCTAssertTrue(listing.contains("README.txt"))
        let summary = try run("/usr/bin/unzip", ["-p", bundle.path, "summary.json"])
        XCTAssertTrue(summary.contains("\"file_names_included\" : false"))
        XCTAssertTrue(summary.contains("spektrafilm-0.9"))
        XCTAssertTrue(summary.contains("\"ended_cleanly\" : false"))
        try run("/usr/bin/unzip", ["-t", bundle.path])

        // The untick replaces the file name everywhere, consistently (§7).
        let logged = try run("/usr/bin/unzip", ["-p", bundle.path,
                                                "logs/\(try XCTUnwrap(log.sessionFile).lastPathComponent)"])
        XCTAssertFalse(logged.contains("DSC03710"), "the frame name survived the untick")
        XCTAssertTrue(logged.contains("frame-0001.ARW"), "the placeholder is not the RFC's shape: \(logged)")
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tool), "\(tool) is not available")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - a superseded render is not an invisible one (§3)

    /// A render the engine ran and the scheduler dropped says so.
    ///
    /// The failure this pins: `superseded` is a field §3 asks for, and the only
    /// place that knows a render was superseded is the scheduler — which used
    /// to discard the result with no callback at all. A record that silently
    /// never says "superseded" is the guard-that-cannot-fire shape, so the
    /// distinction this test draws is between *superseded* (a record with the
    /// engine's own numbers in it) and *never issued* (a different record,
    /// without them).
    ///
    /// **Seen red** by deleting the `else` branch that writes the record: the
    /// test then found no superseded render at all, exactly as a reader of the
    /// log would have.
    func testASupersededRenderIsRecordedWithTheEnginesOwnNumbers() async throws {
        _ = try configure()
        let url = try rawFrame("A7m3/DSC03710.ARW")     // 24 MP: a shoot render is long enough to interrupt
        let session = Session(diagnostics: diagnostics)
        session.open(urls: [url])
        try await waitUntil("the frame to decode", timeout: 120) { session.decoded != nil }
        session.requestPrint()
        try await waitUntil("the print to land", timeout: 180) {
            session.serviceSessionIDForExport != nil && session.frameStates[url] == .processed && !session.busy
        }

        // A shoot-layer edit: the scheduler waits 220 ms and then runs the film
        // side, which on a 24 MP frame takes seconds — long enough that
        // `session.busy` is a reliable "the engine is rendering right now".
        var edited = session.params
        edited.filmStock = "kodak_portra_800"
        session.params = edited
        try await waitUntil("the render to start", timeout: 60) { session.busy }
        session.scheduler.invalidate()     // the generation moves under the render

        try await waitUntil("the superseded record", timeout: 120) {
            log.records().contains { $0.category == .render && $0.message == "superseded" }
        }
        let record = try XCTUnwrap(log.records().first {
            $0.category == .render && $0.message == "superseded"
        })
        XCTAssertEqual(record.level, .info)
        XCTAssertEqual(record.text("outcome"), "superseded")
        // The numbers are the engine's: only a render that really ran has them,
        // which is what separates this record from one for a render that was
        // never issued.
        XCTAssertGreaterThan(record.number("ms") ?? 0, 0)
        XCTAssertGreaterThan(record.number("px") ?? 0, 0)
        XCTAssertEqual(record.text("kind"), "render")
        XCTAssertNotEqual(record.number("generation"), record.number("current_generation"))
    }

    private func rawFrame(_ relativePath: String) throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/\(relativePath)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "\(relativePath) is not in this checkout")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-diag-raw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    // MARK: - the memory projection (§11.5)

    /// A forecast that does not fit is a warning with a record, and the record
    /// is written either way.
    ///
    /// **Seen red** by returning `fits: true` unconditionally from
    /// `projection(pixels:)`: no warning was recorded and no message reached
    /// the window, which is precisely the "sail into a swap storm silently"
    /// failure §11.5 is about.
    func testAProjectionThatDoesNotFitIsWarnedAboutAndRecorded() throws {
        let log = Log(ringCapacity: 64)
        // A machine with 1 GB free against a 45 MP frame's ~7.6 GB forecast.
        let sampler = MemorySampler(log: log, readFootprint: { 100_000_000 }, readFree: { 1_000_000_000 })
        let diagnostics = Diagnostics(defaults: try freshDefaults(), log: log, sampler: sampler)

        let over = diagnostics.noteProjection(pixels: 45_440_000, operation: "develop", frame: "DSC03710.ARW")
        XCTAssertFalse(over.fits)
        XCTAssertNotNil(over.message)
        let warning = try XCTUnwrap(log.records().first { $0.level == .warn && $0.category == .memory })
        XCTAssertEqual(warning.flag("fits"), false)
        XCTAssertEqual(warning.text("op"), "develop")
        XCTAssertEqual(warning.number("px"), 45_440_000)
        XCTAssertGreaterThan(warning.number("forecast_mb") ?? 0, 7_000)

        // The same forecast on a machine with room is recorded too — at debug,
        // because "it fitted" is not news — and says so.
        let roomy = MemorySampler(log: log, readFootprint: { 100_000_000 }, readFree: { 64_000_000_000 })
        let comfortable = Diagnostics(defaults: try freshDefaults(), log: log, sampler: roomy)
        let fine = comfortable.noteProjection(pixels: 1_000_000, operation: "develop", frame: "small.tif")
        XCTAssertTrue(fine.fits)
        XCTAssertNil(fine.message)
        let fits = try XCTUnwrap(log.records().last { $0.category == .memory })
        XCTAssertEqual(fits.flag("fits"), true)
        XCTAssertEqual(fits.level, .debug)

        // And the override is what makes a warning dismissible (§11.5): with
        // it granted, the same frame forecasts as fitting and no message is
        // produced for the window.
        let squeezed = MemorySampler(log: log, readFootprint: { 100_000_000 }, readFree: { 1_000_000_000 })
        let cramped = Diagnostics(defaults: try freshDefaults(), log: log, sampler: squeezed)
        XCTAssertFalse(cramped.projection(pixels: 45_440_000).fits)
        cramped.allowOverReserve = true
        let overridden = cramped.projection(pixels: 45_440_000)
        XCTAssertTrue(overridden.fits, "the override did not take")
        XCTAssertNil(overridden.message)
    }

    /// The reserve is a setting the projection *reads*, is persisted, and is
    /// clamped — the three things that stop it being a number with a settings
    /// row that changes nothing.
    ///
    /// **Seen red** by making `projection` use the default constant instead of
    /// the stored value: raising the reserve stopped moving the verdict.
    func testTheMemoryReserveDecidesTheVerdictAndIsRemembered() throws {
        let log = Log(ringCapacity: 64)
        // 4 GB free against a 1 MP frame's ~167 MB forecast: it fits with the
        // 2 GB default and does not with a 5 GB reserve.
        let sampler = MemorySampler(log: log, readFootprint: { 1 }, readFree: { 4_000_000_000 })
        let defaults = try freshDefaults()
        let diagnostics = Diagnostics(defaults: defaults, log: log, sampler: sampler)
        XCTAssertEqual(diagnostics.memoryReserveMegabytes, Diagnostics.defaultMemoryReserveMB)
        XCTAssertTrue(diagnostics.projection(pixels: 1_000_000).fits)

        diagnostics.memoryReserveMegabytes = 5_000
        XCTAssertEqual(defaults.integer(forKey: "diag.memoryReserveMB"), 5_000,
                       "the reserve was not written down, so the page and the next launch disagree")
        let squeezed = diagnostics.projection(pixels: 1_000_000)
        XCTAssertFalse(squeezed.fits, "a 5 GB reserve did not change the verdict on a 4 GB machine")
        XCTAssertNotNil(squeezed.message)
        XCTAssertEqual(squeezed.reserveBytes, 5_000_000_000)

        // A fresh instance over the same defaults — the next launch — reads it
        // back, and clamps what it is given.
        let relaunched = Diagnostics(defaults: defaults, log: log, sampler: sampler)
        XCTAssertEqual(relaunched.memoryReserveMegabytes, 5_000)
        relaunched.memoryReserveMegabytes = 999_999
        XCTAssertEqual(relaunched.memoryReserveMegabytes, Diagnostics.memoryReserveRange.upperBound)
        relaunched.memoryReserveMegabytes = -1
        XCTAssertEqual(relaunched.memoryReserveMegabytes, 0)
        // "Reserve nothing" is a coherent answer, not an accident.
        XCTAssertTrue(relaunched.projection(pixels: 1_000_000).fits)

        // The retention numbers clamp the same way, and this is not decoration:
        // the first version of all four clamps was written inside a `didSet`
        // that assigned to itself, which under `@Observable` is unbounded
        // recursion — the test process died with SIGSEGV instead of failing,
        // and a Settings-page edit was all it would have taken to do the same
        // to the app. Assigning an out-of-range value here is what pins it.
        relaunched.retentionDays = 9_999
        XCTAssertEqual(relaunched.retentionDays, 365)
        relaunched.retentionMegabytes = 0
        XCTAssertEqual(relaunched.retentionMegabytes, 1)
        relaunched.retentionFiles = 10_000_000
        XCTAssertEqual(relaunched.retentionFiles, 10_000)
        XCTAssertEqual(defaults.integer(forKey: "diag.retentionDays"), 365,
                       "a clamped value was not written down")
    }

    /// A refusal is a visible event (§11.5): a badge in the window, a sentence
    /// in the status line, and an `error` record carrying the engine's own
    /// words beside the user-facing one.
    ///
    /// **Seen red** by dropping the badge from `canvasBadges`: the message was
    /// recorded and the window said nothing.
    func testARefusalIsVisibleInTheWindowAndInTheLog() throws {
        _ = try configure()
        let session = Session(diagnostics: diagnostics)
        session.noteFailure(EngineClient.ClientError.engine(
            "the frame is too large: 14204x10652 is over max_mp 60"), operation: "develop",
            frame: "IQ4.tif", pixels: 151_000_000)

        XCTAssertEqual(session.refusal?.kind, .size)
        XCTAssertEqual(session.canvasBadges.filter { $0.hasPrefix("refused") }.count, 1,
                       "no badge for a refused frame: \(session.canvasBadges)")
        XCTAssertTrue(session.status.contains("larger than Filmify"))
        XCTAssertEqual(session.lastError, session.status)

        let error = try XCTUnwrap(log.records().first { $0.category == .error })
        XCTAssertEqual(error.level, .error)
        XCTAssertEqual(error.text("kind"), "size")
        XCTAssertEqual(error.text("op"), "develop")
        XCTAssertEqual(error.text("raw"), "the frame is too large: 14204x10652 is over max_mp 60")
        XCTAssertNotEqual(error.text("user"), error.text("raw"),
                          "the record does not carry both the engine's words and the user's")
    }

    // MARK: - the job log (§11.4)

    /// An export writes its own record beside its output: which recipe, which
    /// engine build, the per-frame timing and the applied EV.
    ///
    /// **Seen red** by removing the `job.write(beside:)` call: the export
    /// produced a TIFF with no record of how it was made, which is the state
    /// §11.4 exists to end.
    func testAnExportCarriesItsOwnJobLog() async throws {
        _ = try configure()
        let (session, url) = try await developedSession()
        let sessionID = try XCTUnwrap(session.serviceSessionIDForExport)

        var recipe = ExportRecipe()
        recipe.format = .tiff
        recipe.name = "RFC-016 test recipe"
        let context = NamingRule.Context(
            originalName: url.deletingPathExtension().lastPathComponent,
            filmStock: session.params.filmStock,
            printStock: session.params.printStock,
            pixelSize: session.decoded?.pixelSize ?? .zero,
            counter: 1, date: Date())
        let outcome = try await Exporter.export(session: session, recipe: recipe,
                                                context: context, sessionID: sessionID)
        guard case .wrote(let urls, _, _) = outcome else {
            XCTFail("the export was skipped: \(outcome)"); return
        }
        let output = try XCTUnwrap(urls.first)
        let job = JobLog.url(beside: output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.path),
                      "no job log beside \(output.lastPathComponent)")
        let lines = try String(contentsOf: job, encoding: .utf8)
            .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertEqual(lines.first?["msg"] as? String, "export.start", "the job log does not open with the recipe")
        XCTAssertEqual(lines.last?["msg"] as? String, "export.done")
        XCTAssertEqual(lines.first?["marker"] as? String, "job")
        let header = try XCTUnwrap(lines.first)
        XCTAssertEqual(header["film"] as? String, session.params.filmStock)
        XCTAssertEqual(header["print"] as? String, session.params.printStock)
        XCTAssertEqual(header["recipe"] as? String, recipe.name)
        XCTAssertNotNil(header["engine"], "the job log does not say which engine build made the file")
        XCTAssertNotNil(header["render_core"])
        XCTAssertTrue(lines.contains { $0["msg"] as? String == "export.file" })

        // And the session log has the same export, with the EV the render
        // applied — the number that reconciles the file with the approved
        // canvas.
        log.flushNow()
        let record = try XCTUnwrap(log.records().last { $0.category == .export && $0.message == "export" })
        XCTAssertEqual(record.text("format"), ExportFormat.tiff.rawValue)
        XCTAssertEqual(record.number("bit_depth"), 16)
        XCTAssertEqual(record.text("frame"), url.lastPathComponent)
        XCTAssertGreaterThan(record.number("px") ?? 0, 0)
        XCTAssertNotNil(record.number("elapsed_ms"))
    }

    // MARK: - waiting

    private func waitUntil(_ what: String, timeout: Double = 30,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for \(what)")
    }
}
